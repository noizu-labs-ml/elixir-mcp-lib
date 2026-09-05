defmodule Noizu.MCP.Auth.Server.StoreConformanceCase do
  @moduledoc """
  The shared `Noizu.MCP.Auth.Server.Store` test battery. Run against every
  adapter — the two that ship, and any a host writes.

      defmodule MyApp.MCPStoreTest do
        use ExUnit.Case, async: false

        setup do
          %{adapter: MyApp.MCPStore, store_opts: []}
        end

        use Noizu.MCP.Auth.Server.StoreConformanceCase
      end

  The context must carry `:adapter` and `:store_opts`, and the store must start
  empty for each test.

  Two of these tests are the reason this file exists: 20 concurrent redemptions of
  one authorization code, and 20 concurrent rotations of one refresh token. Exactly
  one of each may succeed. An adapter that passes everything else and fails these
  has a race that hands two callers a token from one grant, which is not a bug that
  shows up in ordinary use — it shows up under load, once, in production.
  """

  defmacro __using__(_opts) do
    quote do
      alias Noizu.MCP.Auth.Server.Client
      alias Noizu.MCP.Auth.Server.Secret
      alias Noizu.MCP.Auth.Server.Store
      alias Noizu.MCP.Auth.Server.Store.AccessToken
      alias Noizu.MCP.Auth.Server.Store.AuthorizationCode
      alias Noizu.MCP.Auth.Server.Store.Consent
      alias Noizu.MCP.Auth.Server.Store.RefreshToken

      # ── helpers ──────────────────────────────────────────────────────────

      # Subjects come from the context so the whole battery can be run a second
      # time with uuid subjects against uuid columns. That second pass is the
      # structural guard for a bug that already happened: `Store.Ecto` bound
      # `consent.subject` raw while its seven sibling call sites coerced, and a
      # text-only battery could not see it. Any future missed coercion now fails
      # here rather than in a host application's authorize leg.
      defp subject_a(ctx), do: ctx[:subject_a] || "user-1"
      defp subject_b(ctx), do: ctx[:subject_b] || "user-2"

      defp put_test_client(ctx, overrides \\ []) do
        client =
          struct(
            %Client{
              client_id: "client-" <> Store.generate_token(),
              client_id_kind: :registered,
              client_name: "Conformance",
              redirect_uris: ["https://claude.ai/cb"],
              scope: ["mcp"]
            },
            overrides
          )

        {:ok, stored} = ctx.adapter.put_client(client, ctx.store_opts)
        stored
      end

      defp code_for(ctx, client, overrides \\ []) do
        raw = Store.generate_token()

        record =
          struct(
            %AuthorizationCode{
              code: raw,
              client_id: client.client_id,
              subject: subject_a(ctx),
              redirect_uri: "https://claude.ai/cb",
              scope: ["mcp"],
              resource: "https://app.example.com/mcp",
              code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
              refresh_family_id: Store.generate_id(),
              expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
            },
            overrides
          )

        :ok = ctx.adapter.put_authorization_code(record, ctx.store_opts)
        {raw, record}
      end

      defp refresh_for(ctx, client, overrides \\ []) do
        raw = Store.generate_token()

        record =
          struct(
            %RefreshToken{
              id: Store.generate_id(),
              token: raw,
              client_id: client.client_id,
              subject: subject_a(ctx),
              scope: ["mcp"],
              resource: "https://app.example.com/mcp",
              family_id: Store.generate_id(),
              expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
              family_expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
            },
            overrides
          )

        :ok = ctx.adapter.put_refresh_token(record, ctx.store_opts)
        {raw, record}
      end

      defp next_refresh(record) do
        raw = Store.generate_token()
        {raw, %{record | id: Store.generate_id(), token: raw, rotated_at: nil, rotated_to: nil}}
      end

      # ── clients ──────────────────────────────────────────────────────────

      describe "conformance: clients" do
        test "round-trips a client", ctx do
          client = put_test_client(ctx, client_name: "Round Trip")

          assert {:ok, loaded} = ctx.adapter.get_client(client.client_id, ctx.store_opts)
          assert loaded.client_id == client.client_id
          assert loaded.client_name == "Round Trip"
          assert loaded.client_id_kind == :registered
          assert loaded.redirect_uris == ["https://claude.ai/cb"]
          assert loaded.scope == ["mcp"]
        end

        test "an unknown client is :not_found, not an error", ctx do
          assert {:error, :not_found} = ctx.adapter.get_client("nope", ctx.store_opts)
        end

        test "put_client/2 upserts", ctx do
          client = put_test_client(ctx)
          {:ok, _} = ctx.adapter.put_client(%{client | client_name: "Renamed"}, ctx.store_opts)

          assert {:ok, %{client_name: "Renamed"}} =
                   ctx.adapter.get_client(client.client_id, ctx.store_opts)
        end

        test "stores a pre-hashed secret verbatim — never re-hashed", ctx do
          hash = Secret.hash("s3cret", iterations: 1_000)

          client =
            put_test_client(ctx,
              secret_hash: hash,
              token_endpoint_auth_method: "client_secret_post"
            )

          assert {:ok, loaded} = ctx.adapter.get_client(client.client_id, ctx.store_opts)
          assert loaded.secret_hash == hash
          assert Secret.verify("s3cret", loaded.secret_hash, iterations: 1_000)
        end

        test "carries CIMD bookkeeping", ctx do
          expires = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.truncate(:second)

          client =
            put_test_client(ctx,
              client_id: "https://claude.ai/.well-known/mcp-client",
              client_id_kind: :cimd,
              cimd_etag: ~s("abc123"),
              cimd_expires_at: expires
            )

          assert {:ok, loaded} = ctx.adapter.get_client(client.client_id, ctx.store_opts)
          assert loaded.client_id_kind == :cimd
          assert loaded.cimd_etag == ~s("abc123")
          assert DateTime.truncate(loaded.cimd_expires_at, :second) == expires
        end

        test "delete_client/2, when supported", ctx do
          if Store.supports?(ctx.adapter, {:delete_client, 2}) do
            client = put_test_client(ctx)
            assert :ok = ctx.adapter.delete_client(client.client_id, ctx.store_opts)
            assert {:error, :not_found} = ctx.adapter.get_client(client.client_id, ctx.store_opts)
          end
        end
      end

      # ── login state ──────────────────────────────────────────────────────

      describe "conformance: login state" do
        test "put, get, update and take", ctx do
          state = Store.generate_token()

          assert :ok =
                   ctx.adapter.put_login_state(state, %{"client_id" => "c1"}, 600, ctx.store_opts)

          assert {:ok, %{"client_id" => "c1"}} =
                   ctx.adapter.get_login_state(state, ctx.store_opts)

          assert {:ok, merged} =
                   ctx.adapter.update_login_state(state, %{"subject" => "user-1"}, ctx.store_opts)

          assert merged["client_id"] == "c1"
          assert merged["subject"] == "user-1"

          assert {:ok, taken} = ctx.adapter.take_login_state(state, ctx.store_opts)
          assert taken["subject"] == "user-1"
        end

        test "take consumes: a second take finds nothing", ctx do
          state = Store.generate_token()
          :ok = ctx.adapter.put_login_state(state, %{"a" => 1}, 600, ctx.store_opts)

          assert {:ok, _} = ctx.adapter.take_login_state(state, ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.take_login_state(state, ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.get_login_state(state, ctx.store_opts)
        end

        test "unknown state is :not_found for every read", ctx do
          assert {:error, :not_found} = ctx.adapter.get_login_state("nope", ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.take_login_state("nope", ctx.store_opts)

          assert {:error, :not_found} =
                   ctx.adapter.update_login_state("nope", %{}, ctx.store_opts)
        end

        @tag :slow
        test "expires", ctx do
          state = Store.generate_token()
          :ok = ctx.adapter.put_login_state(state, %{"a" => 1}, 1, ctx.store_opts)
          Process.sleep(1_100)
          assert {:error, :not_found} = ctx.adapter.get_login_state(state, ctx.store_opts)
        end
      end

      # ── authorization codes ──────────────────────────────────────────────

      describe "conformance: authorization codes" do
        test "redeems once, with every binding intact", ctx do
          client = put_test_client(ctx)
          {raw, record} = code_for(ctx, client)

          assert {:ok, redeemed} = ctx.adapter.take_authorization_code(raw, ctx.store_opts)
          assert redeemed.client_id == client.client_id
          assert redeemed.subject == subject_a(ctx)
          assert redeemed.redirect_uri == "https://claude.ai/cb"
          assert redeemed.scope == ["mcp"]
          assert redeemed.resource == "https://app.example.com/mcp"
          assert redeemed.code_challenge == record.code_challenge
          assert redeemed.code_challenge_method == "S256"
          assert redeemed.refresh_family_id == record.refresh_family_id
        end

        test "a second redemption reports a REPLAY, not a miss", ctx do
          client = put_test_client(ctx)
          {raw, record} = code_for(ctx, client)

          assert {:ok, _} = ctx.adapter.take_authorization_code(raw, ctx.store_opts)

          assert {:error, {:replayed, replayed}} =
                   ctx.adapter.take_authorization_code(raw, ctx.store_opts)

          # The family has to come back with it — it is what gets revoked.
          assert replayed.refresh_family_id == record.refresh_family_id
        end

        test "an unknown code is :not_found", ctx do
          assert {:error, :not_found} =
                   ctx.adapter.take_authorization_code(Store.generate_token(), ctx.store_opts)
        end

        test "an expired code is :not_found, not a replay", ctx do
          client = put_test_client(ctx)

          {raw, _record} =
            code_for(ctx, client, expires_at: DateTime.add(DateTime.utc_now(), -30, :second))

          assert {:error, :not_found} = ctx.adapter.take_authorization_code(raw, ctx.store_opts)
        end

        test "bind_authorization_code_family/3", ctx do
          client = put_test_client(ctx)
          {raw, _record} = code_for(ctx, client, refresh_family_id: nil)
          family = Store.generate_id()

          assert :ok = ctx.adapter.bind_authorization_code_family(raw, family, ctx.store_opts)
          assert {:ok, redeemed} = ctx.adapter.take_authorization_code(raw, ctx.store_opts)
          assert redeemed.refresh_family_id == family

          assert {:error, :not_found} =
                   ctx.adapter.bind_authorization_code_family("nope", family, ctx.store_opts)
        end

        test "20 concurrent redemptions: exactly one succeeds", ctx do
          client = put_test_client(ctx)
          {raw, _record} = code_for(ctx, client)

          results =
            1..20
            |> Task.async_stream(
              fn _ -> ctx.adapter.take_authorization_code(raw, ctx.store_opts) end,
              max_concurrency: 20,
              timeout: 10_000
            )
            |> Enum.map(fn {:ok, result} -> result end)

          successes = Enum.count(results, &match?({:ok, _}, &1))
          replays = Enum.count(results, &match?({:error, {:replayed, _}}, &1))

          assert successes == 1, "expected exactly one redemption, got #{successes}"
          assert successes + replays == 20, "every loser must report a replay"
        end
      end

      # ── refresh tokens ───────────────────────────────────────────────────

      describe "conformance: refresh tokens" do
        test "round-trips", ctx do
          client = put_test_client(ctx)
          {raw, record} = refresh_for(ctx, client)

          assert {:ok, loaded} = ctx.adapter.get_refresh_token(raw, ctx.store_opts)
          assert loaded.client_id == client.client_id
          assert loaded.subject == subject_a(ctx)
          assert loaded.scope == ["mcp"]
          assert loaded.family_id == record.family_id
        end

        test "rotation retires the old token and issues the new one", ctx do
          client = put_test_client(ctx)
          {raw, record} = refresh_for(ctx, client)
          {new_raw, new_record} = next_refresh(record)

          assert {:ok, old} = ctx.adapter.rotate_refresh_token(raw, new_record, ctx.store_opts)
          assert old.family_id == record.family_id

          # The old one no longer reads as usable...
          assert {:error, :not_found} = ctx.adapter.get_refresh_token(raw, ctx.store_opts)
          # ...and the new one inherits the family and its deadline.
          assert {:ok, rotated} = ctx.adapter.get_refresh_token(new_raw, ctx.store_opts)
          assert rotated.family_id == record.family_id
          refute is_nil(rotated.family_expires_at)
        end

        test "reusing a rotated token reports a REPLAY with its family", ctx do
          client = put_test_client(ctx)
          {raw, record} = refresh_for(ctx, client)
          {_new_raw, new_record} = next_refresh(record)

          assert {:ok, _} = ctx.adapter.rotate_refresh_token(raw, new_record, ctx.store_opts)

          {_third_raw, third} = next_refresh(record)

          assert {:error, {:replayed, replayed}} =
                   ctx.adapter.rotate_refresh_token(raw, third, ctx.store_opts)

          assert replayed.family_id == record.family_id
        end

        test "an unknown, expired or revoked token cannot rotate", ctx do
          client = put_test_client(ctx)
          {_raw, template} = refresh_for(ctx, client)
          {_new, new_record} = next_refresh(template)

          assert {:error, :not_found} =
                   ctx.adapter.rotate_refresh_token(
                     Store.generate_token(),
                     new_record,
                     ctx.store_opts
                   )

          {expired_raw, expired} =
            refresh_for(ctx, client, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

          {_r, replacement} = next_refresh(expired)

          assert {:error, :not_found} =
                   ctx.adapter.rotate_refresh_token(expired_raw, replacement, ctx.store_opts)

          {revoked_raw, revoked} = refresh_for(ctx, client)
          :ok = ctx.adapter.revoke_refresh_token(revoked_raw, ctx.store_opts)
          {_r2, replacement2} = next_refresh(revoked)

          assert {:error, :not_found} =
                   ctx.adapter.rotate_refresh_token(revoked_raw, replacement2, ctx.store_opts)
        end

        test "revoke_refresh_token/2 is idempotent and tolerates unknown tokens", ctx do
          client = put_test_client(ctx)
          {raw, _record} = refresh_for(ctx, client)

          assert :ok = ctx.adapter.revoke_refresh_token(raw, ctx.store_opts)
          assert :ok = ctx.adapter.revoke_refresh_token(raw, ctx.store_opts)
          assert :ok = ctx.adapter.revoke_refresh_token("nope", ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.get_refresh_token(raw, ctx.store_opts)
        end

        test "revoke_refresh_family/2 takes out the whole chain", ctx do
          client = put_test_client(ctx)
          family = Store.generate_id()
          {a, _} = refresh_for(ctx, client, family_id: family)
          {b, _} = refresh_for(ctx, client, family_id: family)
          {other, _} = refresh_for(ctx, client)

          assert :ok = ctx.adapter.revoke_refresh_family(family, ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.get_refresh_token(a, ctx.store_opts)
          assert {:error, :not_found} = ctx.adapter.get_refresh_token(b, ctx.store_opts)
          # A different family is untouched.
          assert {:ok, _} = ctx.adapter.get_refresh_token(other, ctx.store_opts)
        end

        test "revoke_subject_tokens/3, when supported", ctx do
          if Store.supports?(ctx.adapter, {:revoke_subject_tokens, 3}) do
            client = put_test_client(ctx)
            other_client = put_test_client(ctx)
            {mine, _} = refresh_for(ctx, client, subject: subject_a(ctx))
            {also_mine, _} = refresh_for(ctx, other_client, subject: subject_a(ctx))
            {theirs, _} = refresh_for(ctx, client, subject: subject_b(ctx))

            assert :ok =
                     ctx.adapter.revoke_subject_tokens(
                       subject_a(ctx),
                       client.client_id,
                       ctx.store_opts
                     )

            assert {:error, :not_found} = ctx.adapter.get_refresh_token(mine, ctx.store_opts)
            assert {:ok, _} = ctx.adapter.get_refresh_token(also_mine, ctx.store_opts)
            assert {:ok, _} = ctx.adapter.get_refresh_token(theirs, ctx.store_opts)

            assert :ok = ctx.adapter.revoke_subject_tokens(subject_a(ctx), nil, ctx.store_opts)
            assert {:error, :not_found} = ctx.adapter.get_refresh_token(also_mine, ctx.store_opts)
            assert {:ok, _} = ctx.adapter.get_refresh_token(theirs, ctx.store_opts)
          end
        end

        test "20 concurrent rotations: exactly one succeeds", ctx do
          client = put_test_client(ctx)
          {raw, record} = refresh_for(ctx, client)

          results =
            1..20
            |> Task.async_stream(
              fn _ ->
                {_new_raw, candidate} = next_refresh(record)
                ctx.adapter.rotate_refresh_token(raw, candidate, ctx.store_opts)
              end,
              max_concurrency: 20,
              timeout: 10_000
            )
            |> Enum.map(fn {:ok, result} -> result end)

          successes = Enum.count(results, &match?({:ok, _}, &1))
          replays = Enum.count(results, &match?({:error, {:replayed, _}}, &1))

          assert successes == 1, "expected exactly one rotation, got #{successes}"
          assert successes + replays == 20, "every loser must report a replay"
        end
      end

      # ── consent ──────────────────────────────────────────────────────────

      describe "conformance: consent" do
        test "round-trips and upserts on {subject, client_id}", ctx do
          client = put_test_client(ctx)

          consent = %Consent{
            subject: subject_a(ctx),
            client_id: client.client_id,
            scope: ["mcp"],
            resource: "https://app.example.com/mcp"
          }

          assert :ok = ctx.adapter.put_consent(consent, ctx.store_opts)

          assert {:ok, loaded} =
                   ctx.adapter.get_consent(subject_a(ctx), client.client_id, ctx.store_opts)

          assert loaded.scope == ["mcp"]
          refute is_nil(loaded.granted_at)

          assert :ok =
                   ctx.adapter.put_consent(
                     %{consent | scope: ["mcp", "mcp:admin"]},
                     ctx.store_opts
                   )

          assert {:ok, updated} =
                   ctx.adapter.get_consent(subject_a(ctx), client.client_id, ctx.store_opts)

          assert updated.scope == ["mcp", "mcp:admin"]
        end

        test "consent is per subject and per client", ctx do
          client = put_test_client(ctx)
          other = put_test_client(ctx)

          :ok =
            ctx.adapter.put_consent(
              %Consent{subject: subject_a(ctx), client_id: client.client_id, scope: ["mcp"]},
              ctx.store_opts
            )

          assert {:error, :not_found} =
                   ctx.adapter.get_consent(subject_b(ctx), client.client_id, ctx.store_opts)

          assert {:error, :not_found} =
                   ctx.adapter.get_consent(subject_a(ctx), other.client_id, ctx.store_opts)
        end

        test "revoke_consent/3 is idempotent", ctx do
          client = put_test_client(ctx)

          :ok =
            ctx.adapter.put_consent(
              %Consent{subject: subject_a(ctx), client_id: client.client_id, scope: ["mcp"]},
              ctx.store_opts
            )

          assert :ok =
                   ctx.adapter.revoke_consent(subject_a(ctx), client.client_id, ctx.store_opts)

          assert :ok =
                   ctx.adapter.revoke_consent(subject_a(ctx), client.client_id, ctx.store_opts)

          assert {:error, :not_found} =
                   ctx.adapter.get_consent(subject_a(ctx), client.client_id, ctx.store_opts)
        end
      end

      # ── access tokens (optional) ─────────────────────────────────────────

      describe "conformance: access tokens" do
        test "track and revoke, when supported", ctx do
          if Store.supports?(ctx.adapter, {:put_access_token, 2}) do
            client = put_test_client(ctx)
            jti = Store.generate_token()

            record = %AccessToken{
              jti: jti,
              client_id: client.client_id,
              subject: subject_a(ctx),
              scope: ["mcp"],
              resource: "https://app.example.com/mcp",
              expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
            }

            assert :ok = ctx.adapter.put_access_token(record, ctx.store_opts)
            refute ctx.adapter.access_token_revoked?(jti, ctx.store_opts)

            assert :ok = ctx.adapter.revoke_access_token(jti, ctx.store_opts)
            assert ctx.adapter.access_token_revoked?(jti, ctx.store_opts)
          end
        end

        test "an untracked token does not read as revoked", ctx do
          if Store.supports?(ctx.adapter, {:access_token_revoked?, 2}) do
            # With `track_access_tokens: false` there is no row for any token, so
            # "no row" must mean "not revoked" or every request would 401.
            refute ctx.adapter.access_token_revoked?(Store.generate_token(), ctx.store_opts)
          end
        end
      end

      # ── purge ────────────────────────────────────────────────────────────

      describe "conformance: purge_expired" do
        test "removes expired rows and leaves live ones, when supported", ctx do
          if Store.supports?(ctx.adapter, {:purge_expired, 2}) do
            client = put_test_client(ctx)
            past = DateTime.add(DateTime.utc_now(), -3_600, :second)

            {expired_code, _} = code_for(ctx, client, expires_at: past)
            {live_code, _} = code_for(ctx, client)
            {expired_refresh, _} = refresh_for(ctx, client, expires_at: past)
            {live_refresh, _} = refresh_for(ctx, client)

            assert {:ok, counts} = ctx.adapter.purge_expired(DateTime.utc_now(), ctx.store_opts)
            assert is_map(counts)

            assert {:error, :not_found} =
                     ctx.adapter.take_authorization_code(expired_code, ctx.store_opts)

            assert {:ok, _} = ctx.adapter.take_authorization_code(live_code, ctx.store_opts)

            assert {:error, :not_found} =
                     ctx.adapter.get_refresh_token(expired_refresh, ctx.store_opts)

            assert {:ok, _} = ctx.adapter.get_refresh_token(live_refresh, ctx.store_opts)
          end
        end
      end
    end
  end
end
