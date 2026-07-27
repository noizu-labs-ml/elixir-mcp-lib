if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Auth.Server.Store.Ecto do
    @moduledoc """
    Postgres `Noizu.MCP.Auth.Server.Store` adapter, in **raw SQL**.

        store: {Noizu.MCP.Auth.Server.Store.Ecto, repo: MyApp.Repo}

    ## No Ecto schemas, deliberately

    The library defines no schema modules and no migrations. A schema is a claim
    about a table the host owns; two apps with slightly different columns would
    both be broken by one library change, and a `mix ecto.gen.migration` here
    would collide with a host that uses Liquibase (both of ours do). What ships
    instead is `priv/liquibase/noizu_mcp_oauth.yaml`, which the host copies into
    its own changelog directory and owns from then on. This adapter speaks to
    those tables through `Ecto.Adapters.SQL.query/4` and nothing else.

    ## Options

      * `:repo` (required) — an `Ecto.Repo`
      * `:prefix` — Postgres schema qualifier, e.g. `"mcp"`
      * `:timeout` — query timeout, default 5s

    ## Atomicity

    `take_authorization_code/2` is a single
    `UPDATE … SET used_at = now() WHERE code_hash = $1 AND used_at IS NULL RETURNING *`.
    Two concurrent redemptions both reach the row; exactly one updates it; the
    loser's zero-row result is then disambiguated by a follow-up `SELECT`, which
    tells "never existed" from **"already used"**. The latter is a replay and
    revokes the refresh family.

    `rotate_refresh_token/3` is the same shape — a guarded `UPDATE … WHERE
    rotated_at IS NULL AND revoked_at IS NULL RETURNING *`, with the new row
    inserted in the same transaction — so one refresh token cannot be exchanged
    twice, and a second attempt is reported as a replay rather than as a miss.
    """

    @behaviour Noizu.MCP.Auth.Server.Store

    alias Noizu.MCP.Auth.Server.Client
    alias Noizu.MCP.Auth.Server.Secret
    alias Noizu.MCP.Auth.Server.Store
    alias Noizu.MCP.Auth.Server.Store.AccessToken
    alias Noizu.MCP.Auth.Server.Store.AuthorizationCode
    alias Noizu.MCP.Auth.Server.Store.Consent
    alias Noizu.MCP.Auth.Server.Store.RefreshToken

    @client_columns ~w(client_id client_id_kind client_name secret_hash token_endpoint_auth_method
                       redirect_uris grant_types response_types scope upstream_client_ref logo_uri
                       client_uri policy_uri tos_uri software_id software_version cimd_fetched_at
                       cimd_etag cimd_expires_at metadata disabled_at inserted_at updated_at)

    @code_columns ~w(code_hash client_id subject redirect_uri scope resource code_challenge
                     code_challenge_method nonce refresh_family_id upstream_ref expires_at used_at
                     inserted_at)

    @refresh_columns ~w(id token_hash client_id subject scope resource family_id rotated_to
                        rotated_at revoked_at expires_at family_expires_at inserted_at)

    @consent_columns ~w(subject client_id scope resource granted_at expires_at)

    # ── clients ────────────────────────────────────────────────────────────

    @impl Store
    def get_client(client_id, opts) do
      case query(
             opts,
             "SELECT #{cols(@client_columns)} FROM #{table(opts, "clients")} WHERE client_id = $1",
             [
               client_id
             ]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, to_client(row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    @impl Store
    def put_client(%Client{} = client, opts) do
      sql = """
      INSERT INTO #{table(opts, "clients")}
        (client_id, client_id_kind, client_name, secret_hash, token_endpoint_auth_method,
         redirect_uris, grant_types, response_types, scope, upstream_client_ref, logo_uri,
         client_uri, policy_uri, tos_uri, software_id, software_version, cimd_fetched_at,
         cimd_etag, cimd_expires_at, metadata, disabled_at, inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,now(),now())
      ON CONFLICT (client_id) DO UPDATE SET
        client_id_kind = EXCLUDED.client_id_kind,
        client_name = EXCLUDED.client_name,
        secret_hash = EXCLUDED.secret_hash,
        token_endpoint_auth_method = EXCLUDED.token_endpoint_auth_method,
        redirect_uris = EXCLUDED.redirect_uris,
        grant_types = EXCLUDED.grant_types,
        response_types = EXCLUDED.response_types,
        scope = EXCLUDED.scope,
        upstream_client_ref = EXCLUDED.upstream_client_ref,
        logo_uri = EXCLUDED.logo_uri,
        client_uri = EXCLUDED.client_uri,
        policy_uri = EXCLUDED.policy_uri,
        tos_uri = EXCLUDED.tos_uri,
        software_id = EXCLUDED.software_id,
        software_version = EXCLUDED.software_version,
        cimd_fetched_at = EXCLUDED.cimd_fetched_at,
        cimd_etag = EXCLUDED.cimd_etag,
        cimd_expires_at = EXCLUDED.cimd_expires_at,
        metadata = EXCLUDED.metadata,
        disabled_at = EXCLUDED.disabled_at,
        updated_at = now()
      RETURNING #{cols(@client_columns)}
      """

      params = [
        client.client_id,
        to_string(client.client_id_kind),
        client.client_name,
        client.secret_hash,
        client.token_endpoint_auth_method,
        json(client.redirect_uris),
        json(client.grant_types),
        json(client.response_types),
        scope_text(client.scope),
        client.upstream_client_ref,
        client.logo_uri,
        client.client_uri,
        client.policy_uri,
        client.tos_uri,
        client.software_id,
        client.software_version,
        client.cimd_fetched_at,
        client.cimd_etag,
        client.cimd_expires_at,
        json(client.metadata),
        client.disabled_at
      ]

      case query(opts, sql, params) do
        {:ok, %{rows: [row]}} -> {:ok, to_client(row)}
        error -> error
      end
    end

    @impl Store
    def delete_client(client_id, opts) do
      with {:ok, _} <-
             query(opts, "DELETE FROM #{table(opts, "clients")} WHERE client_id = $1", [client_id]),
           do: :ok
    end

    # ── login state ────────────────────────────────────────────────────────

    @impl Store
    def put_login_state(state, payload, ttl, opts) do
      sql = """
      INSERT INTO #{table(opts, "login_states")} (state_hash, payload, expires_at, inserted_at, updated_at)
      VALUES ($1, $2, now() + ($3 || ' seconds')::interval, now(), now())
      ON CONFLICT (state_hash) DO UPDATE SET
        payload = EXCLUDED.payload, expires_at = EXCLUDED.expires_at, updated_at = now()
      """

      with {:ok, _} <-
             query(opts, sql, [Secret.token_hash(state), json(payload), to_string(ttl)]),
           do: :ok
    end

    @impl Store
    def get_login_state(state, opts) do
      sql = """
      SELECT payload FROM #{table(opts, "login_states")}
      WHERE state_hash = $1 AND expires_at > now()
      """

      case query(opts, sql, [Secret.token_hash(state)]) do
        {:ok, %{rows: [[payload]]}} -> {:ok, payload || %{}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    @impl Store
    def update_login_state(state, changes, opts) do
      # `||` on jsonb is a shallow merge — exactly the semantics of
      # `Map.merge/2`, done in one statement so no read-modify-write races.
      sql = """
      UPDATE #{table(opts, "login_states")}
      SET payload = payload || $2, updated_at = now()
      WHERE state_hash = $1 AND expires_at > now()
      RETURNING payload
      """

      case query(opts, sql, [Secret.token_hash(state), json(changes)]) do
        {:ok, %{rows: [[payload]]}} -> {:ok, payload || %{}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    @impl Store
    def take_login_state(state, opts) do
      sql = """
      DELETE FROM #{table(opts, "login_states")}
      WHERE state_hash = $1 AND expires_at > now()
      RETURNING payload
      """

      case query(opts, sql, [Secret.token_hash(state)]) do
        {:ok, %{rows: [[payload]]}} -> {:ok, payload || %{}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    # ── authorization codes ────────────────────────────────────────────────

    @impl Store
    def put_authorization_code(%AuthorizationCode{} = code, opts) do
      sql = """
      INSERT INTO #{table(opts, "authorization_codes")}
        (code_hash, client_id, subject, redirect_uri, scope, resource, code_challenge,
         code_challenge_method, nonce, refresh_family_id, upstream_ref, expires_at, inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,now())
      """

      params = [
        Secret.token_hash(code.code),
        code.client_id,
        code.subject,
        code.redirect_uri,
        scope_text(code.scope),
        code.resource,
        code.code_challenge,
        code.code_challenge_method,
        code.nonce,
        code.refresh_family_id,
        json(code.upstream_ref),
        code.expires_at
      ]

      with {:ok, _} <- query(opts, sql, params), do: :ok
    end

    @impl Store
    def take_authorization_code(code, opts) do
      hash = Secret.token_hash(code)

      sql = """
      UPDATE #{table(opts, "authorization_codes")}
      SET used_at = now()
      WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now()
      RETURNING #{cols(@code_columns)}
      """

      case query(opts, sql, [hash]) do
        {:ok, %{rows: [row]}} ->
          {:ok, to_code(row)}

        {:ok, %{rows: []}} ->
          # Zero rows is ambiguous: unknown, expired, or already redeemed. Only
          # the third is a replay, and a replay must revoke the family.
          replayed_code(hash, opts)

        error ->
          error
      end
    end

    @impl Store
    def bind_authorization_code_family(code, family_id, opts) do
      sql = """
      UPDATE #{table(opts, "authorization_codes")} SET refresh_family_id = $2 WHERE code_hash = $1
      """

      case query(opts, sql, [Secret.token_hash(code), family_id]) do
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:ok, _} -> :ok
        error -> error
      end
    end

    # ── refresh tokens ─────────────────────────────────────────────────────

    @impl Store
    def put_refresh_token(%RefreshToken{} = token, opts) do
      with {:ok, _} <- insert_refresh(token, opts), do: :ok
    end

    @impl Store
    def get_refresh_token(token, opts) do
      sql = """
      SELECT #{cols(@refresh_columns)} FROM #{table(opts, "refresh_tokens")}
      WHERE token_hash = $1 AND revoked_at IS NULL AND rotated_at IS NULL AND expires_at > now()
      """

      case query(opts, sql, [Secret.token_hash(token)]) do
        {:ok, %{rows: [row]}} -> {:ok, to_refresh(row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    @impl Store
    def rotate_refresh_token(old_token, %RefreshToken{} = new_token, opts) do
      hash = Secret.token_hash(old_token)
      repo = repo!(opts)

      result =
        repo.transaction(fn ->
          claim = """
          UPDATE #{table(opts, "refresh_tokens")}
          SET rotated_at = now()
          WHERE token_hash = $1 AND rotated_at IS NULL AND revoked_at IS NULL
            AND expires_at > now()
            AND (family_expires_at IS NULL OR family_expires_at > now())
          RETURNING #{cols(@refresh_columns)}
          """

          case query(opts, claim, [hash]) do
            {:ok, %{rows: [row]}} ->
              old = to_refresh(row)

              inserted =
                insert_refresh(
                  %{
                    new_token
                    | family_id: old.family_id,
                      family_expires_at: old.family_expires_at
                  },
                  opts
                )

              case inserted do
                {:ok, new} ->
                  link =
                    "UPDATE #{table(opts, "refresh_tokens")} SET rotated_to = $2 WHERE id = $1"

                  case query(opts, link, [old.id, new.id]) do
                    {:ok, _} -> {:ok, old}
                    {:error, reason} -> repo.rollback(reason)
                  end

                {:error, reason} ->
                  repo.rollback(reason)
              end

            {:ok, %{rows: []}} ->
              replayed_refresh(hash, opts)

            {:error, reason} ->
              repo.rollback(reason)
          end
        end)

      case result do
        {:ok, inner} -> inner
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Store
    def revoke_refresh_token(token, opts) do
      sql = """
      UPDATE #{table(opts, "refresh_tokens")} SET revoked_at = now()
      WHERE token_hash = $1 AND revoked_at IS NULL
      """

      with {:ok, _} <- query(opts, sql, [Secret.token_hash(token)]), do: :ok
    end

    @impl Store
    def revoke_refresh_family(family_id, opts) do
      sql = """
      UPDATE #{table(opts, "refresh_tokens")} SET revoked_at = now()
      WHERE family_id = $1 AND revoked_at IS NULL
      """

      with {:ok, _} <- query(opts, sql, [family_id]), do: :ok
    end

    @impl Store
    def revoke_subject_tokens(subject, nil, opts) do
      sql = """
      UPDATE #{table(opts, "refresh_tokens")} SET revoked_at = now()
      WHERE subject = $1 AND revoked_at IS NULL
      """

      with {:ok, _} <- query(opts, sql, [subject]), do: :ok
    end

    def revoke_subject_tokens(subject, client_id, opts) do
      sql = """
      UPDATE #{table(opts, "refresh_tokens")} SET revoked_at = now()
      WHERE subject = $1 AND client_id = $2 AND revoked_at IS NULL
      """

      with {:ok, _} <- query(opts, sql, [subject, client_id]), do: :ok
    end

    # ── consent ────────────────────────────────────────────────────────────

    @impl Store
    def get_consent(subject, client_id, opts) do
      sql = """
      SELECT #{cols(@consent_columns)} FROM #{table(opts, "consents")}
      WHERE subject = $1 AND client_id = $2 AND (expires_at IS NULL OR expires_at > now())
      """

      case query(opts, sql, [subject, client_id]) do
        {:ok, %{rows: [row]}} -> {:ok, to_consent(row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    @impl Store
    def put_consent(%Consent{} = consent, opts) do
      sql = """
      INSERT INTO #{table(opts, "consents")} (subject, client_id, scope, resource, granted_at, expires_at)
      VALUES ($1,$2,$3,$4,now(),$5)
      ON CONFLICT (subject, client_id) DO UPDATE SET
        scope = EXCLUDED.scope, resource = EXCLUDED.resource,
        granted_at = now(), expires_at = EXCLUDED.expires_at
      """

      params = [
        consent.subject,
        consent.client_id,
        scope_text(consent.scope),
        consent.resource,
        consent.expires_at
      ]

      with {:ok, _} <- query(opts, sql, params), do: :ok
    end

    @impl Store
    def revoke_consent(subject, client_id, opts) do
      sql = "DELETE FROM #{table(opts, "consents")} WHERE subject = $1 AND client_id = $2"
      with {:ok, _} <- query(opts, sql, [subject, client_id]), do: :ok
    end

    # ── access tokens ──────────────────────────────────────────────────────

    @impl Store
    def put_access_token(%AccessToken{} = token, opts) do
      sql = """
      INSERT INTO #{table(opts, "access_tokens")}
        (jti_hash, client_id, subject, scope, resource, family_id, expires_at, inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,now())
      ON CONFLICT (jti_hash) DO NOTHING
      """

      params = [
        Secret.token_hash(token.jti),
        token.client_id,
        token.subject,
        scope_text(token.scope),
        token.resource,
        token.family_id,
        token.expires_at
      ]

      with {:ok, _} <- query(opts, sql, params), do: :ok
    end

    @impl Store
    def access_token_revoked?(jti, opts) do
      sql = """
      SELECT revoked_at IS NOT NULL FROM #{table(opts, "access_tokens")} WHERE jti_hash = $1
      """

      case query(opts, sql, [Secret.token_hash(jti)]) do
        {:ok, %{rows: [[revoked]]}} -> revoked
        # No row: either tracking is off or the row was purged. Not revoked.
        {:ok, %{rows: []}} -> false
        error -> error
      end
    end

    @impl Store
    def revoke_access_token(jti, opts) do
      sql = """
      UPDATE #{table(opts, "access_tokens")} SET revoked_at = now()
      WHERE jti_hash = $1 AND revoked_at IS NULL
      """

      with {:ok, _} <- query(opts, sql, [Secret.token_hash(jti)]), do: :ok
    end

    @impl Store
    def purge_expired(now, opts) do
      # Codes are kept past expiry only as long as replay detection needs them;
      # once expired they can never be redeemed, so there is nothing to detect.
      purges = [
        login_states: "DELETE FROM #{table(opts, "login_states")} WHERE expires_at < $1",
        authorization_codes:
          "DELETE FROM #{table(opts, "authorization_codes")} WHERE expires_at < $1",
        refresh_tokens:
          "DELETE FROM #{table(opts, "refresh_tokens")} WHERE expires_at < $1 AND rotated_to IS NULL",
        access_tokens: "DELETE FROM #{table(opts, "access_tokens")} WHERE expires_at < $1"
      ]

      Enum.reduce_while(purges, {:ok, %{}}, fn {name, sql}, {:ok, counts} ->
        case query(opts, sql, [now]) do
          {:ok, %{num_rows: rows}} -> {:cont, {:ok, Map.put(counts, name, rows)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    # ── internals ──────────────────────────────────────────────────────────

    defp insert_refresh(%RefreshToken{} = token, opts) do
      sql = """
      INSERT INTO #{table(opts, "refresh_tokens")}
        (id, token_hash, client_id, subject, scope, resource, family_id, expires_at,
         family_expires_at, inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,now())
      RETURNING #{cols(@refresh_columns)}
      """

      params = [
        token.id || Store.generate_id(),
        Secret.token_hash(token.token),
        token.client_id,
        token.subject,
        scope_text(token.scope),
        token.resource,
        token.family_id,
        token.expires_at,
        token.family_expires_at
      ]

      case query(opts, sql, params) do
        {:ok, %{rows: [row]}} -> {:ok, to_refresh(row)}
        error -> error
      end
    end

    defp replayed_code(hash, opts) do
      sql = """
      SELECT #{cols(@code_columns)} FROM #{table(opts, "authorization_codes")}
      WHERE code_hash = $1 AND used_at IS NOT NULL
      """

      case query(opts, sql, [hash]) do
        {:ok, %{rows: [row]}} -> {:error, {:replayed, to_code(row)}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    defp replayed_refresh(hash, opts) do
      sql = """
      SELECT #{cols(@refresh_columns)} FROM #{table(opts, "refresh_tokens")}
      WHERE token_hash = $1 AND rotated_at IS NOT NULL AND revoked_at IS NULL
      """

      case query(opts, sql, [hash]) do
        {:ok, %{rows: [row]}} -> {:error, {:replayed, to_refresh(row)}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        error -> error
      end
    end

    defp to_client(row) do
      fields = row_map(@client_columns, row)

      %Client{
        client_id: fields["client_id"],
        client_id_kind: kind(fields["client_id_kind"]),
        client_name: fields["client_name"],
        secret_hash: fields["secret_hash"],
        token_endpoint_auth_method: fields["token_endpoint_auth_method"],
        redirect_uris: list(fields["redirect_uris"]),
        grant_types: list(fields["grant_types"]),
        response_types: list(fields["response_types"]),
        scope: scope_list(fields["scope"]),
        upstream_client_ref: fields["upstream_client_ref"],
        logo_uri: fields["logo_uri"],
        client_uri: fields["client_uri"],
        policy_uri: fields["policy_uri"],
        tos_uri: fields["tos_uri"],
        software_id: fields["software_id"],
        software_version: fields["software_version"],
        cimd_fetched_at: fields["cimd_fetched_at"],
        cimd_etag: fields["cimd_etag"],
        cimd_expires_at: fields["cimd_expires_at"],
        metadata: fields["metadata"] || %{},
        disabled_at: fields["disabled_at"],
        inserted_at: fields["inserted_at"],
        updated_at: fields["updated_at"]
      }
    end

    defp to_code(row) do
      fields = row_map(@code_columns, row)

      %AuthorizationCode{
        client_id: fields["client_id"],
        subject: fields["subject"],
        redirect_uri: fields["redirect_uri"],
        scope: scope_list(fields["scope"]),
        resource: fields["resource"],
        code_challenge: fields["code_challenge"],
        code_challenge_method: fields["code_challenge_method"],
        nonce: fields["nonce"],
        refresh_family_id: uuid(fields["refresh_family_id"]),
        upstream_ref: fields["upstream_ref"],
        expires_at: fields["expires_at"],
        used_at: fields["used_at"],
        inserted_at: fields["inserted_at"]
      }
    end

    defp to_refresh(row) do
      fields = row_map(@refresh_columns, row)

      %RefreshToken{
        id: uuid(fields["id"]),
        client_id: fields["client_id"],
        subject: fields["subject"],
        scope: scope_list(fields["scope"]),
        resource: fields["resource"],
        family_id: uuid(fields["family_id"]),
        rotated_to: uuid(fields["rotated_to"]),
        rotated_at: fields["rotated_at"],
        revoked_at: fields["revoked_at"],
        expires_at: fields["expires_at"],
        family_expires_at: fields["family_expires_at"],
        inserted_at: fields["inserted_at"]
      }
    end

    defp to_consent(row) do
      fields = row_map(@consent_columns, row)

      %Consent{
        subject: fields["subject"],
        client_id: fields["client_id"],
        scope: scope_list(fields["scope"]),
        resource: fields["resource"],
        granted_at: fields["granted_at"],
        expires_at: fields["expires_at"]
      }
    end

    defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

    # `id`/`family_id` are uuid columns; Postgrex hands them back as 16-byte
    # binaries unless the repo is configured otherwise, so normalize to text.
    defp uuid(<<_::128>> = raw) do
      raw
      |> Base.encode16(case: :lower)
      |> then(fn hex ->
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ]
        |> Enum.join("-")
      end)
    end

    defp uuid(other), do: other

    defp kind(value) when is_binary(value) do
      case value do
        "cimd" -> :cimd
        "preconfigured" -> :preconfigured
        _ -> :registered
      end
    end

    defp kind(_value), do: :registered

    defp list(value) when is_list(value), do: value
    defp list(_value), do: []

    defp scope_text(scope) when is_list(scope), do: Enum.join(scope, " ")
    defp scope_text(scope) when is_binary(scope), do: scope
    defp scope_text(_scope), do: ""

    defp scope_list(scope) when is_binary(scope), do: String.split(scope, " ", trim: true)
    defp scope_list(_scope), do: []

    defp json(nil), do: nil
    defp json(value), do: value

    defp cols(columns), do: Enum.join(columns, ", ")

    defp table(opts, name) do
      case Keyword.get(opts, :prefix) do
        nil -> "mcp_oauth_" <> name
        prefix -> ~s("#{prefix}".mcp_oauth_#{name})
      end
    end

    defp repo!(opts) do
      Keyword.get(opts, :repo) ||
        raise ArgumentError, "Store.Ecto requires `repo:` in its store options"
    end

    defp query(opts, sql, params) do
      repo = repo!(opts)
      timeout = Keyword.get(opts, :timeout, 5_000)

      case Ecto.Adapters.SQL.query(repo, sql, Enum.map(params, &encode/1), timeout: timeout) do
        {:ok, result} -> {:ok, normalize(result)}
        {:error, reason} -> {:error, {:store_error, reason}}
      end
    end

    # Maps and lists go into jsonb columns; Postgrex encodes them via the repo's
    # JSON library, so they pass through as-is.
    defp encode(value), do: value

    defp normalize(%{rows: nil} = result), do: %{result | rows: []}

    defp normalize(%{rows: rows} = result) when is_list(rows),
      do: %{result | rows: Enum.map(rows, fn row -> Enum.map(row, &normalize_value/1) end)}

    # Only timestamps are normalized blanket-wise. uuid columns are converted by
    # name in the `to_*` mappers — a blanket "16-byte binary is a uuid" rule
    # would mangle any text value that happens to be 16 characters long.
    defp normalize_value(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
    defp normalize_value(value), do: value
  end
end
