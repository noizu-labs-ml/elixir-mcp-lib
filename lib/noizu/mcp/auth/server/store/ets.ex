defmodule Noizu.MCP.Auth.Server.Store.ETS do
  @moduledoc """
  In-memory `Noizu.MCP.Auth.Server.Store` adapter.

  For development, for tests, and for a single-replica deployment that can afford
  to lose OAuth state on restart (losing it costs a re-login, not data). **Not
  clustered** — each node would hold its own codes, and a token request that
  landed on the wrong node would fail.

  ## Why a GenServer

  Reads go straight to ETS. Every *mutation* goes through the owning process, and
  that serialization is what makes `take_authorization_code/2` and
  `rotate_refresh_token/3` genuinely atomic: two concurrent redemptions of one
  code are two messages in one mailbox, and the second sees `used_at` already set.
  Doing it with bare ETS would need a compare-and-swap per operation; a mailbox is
  simpler and, at authorization-code volumes, indistinguishable in cost.

      children = [
        {Noizu.MCP.Auth.Server.Store.ETS, name: MyApp.MCPOAuthStore}
      ]

      store: {Noizu.MCP.Auth.Server.Store.ETS, name: MyApp.MCPOAuthStore}

  Hashing follows the behaviour: raw credentials in, `Secret.token_hash/1` keys
  stored. An in-memory store has no attacker-readable table, but a heap dump and a
  crash log are both real, and an adapter that stores plaintext here would teach
  the wrong shape to whoever copies it.
  """

  @behaviour Noizu.MCP.Auth.Server.Store

  use GenServer

  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Store.AccessToken
  alias Noizu.MCP.Auth.Server.Store.AuthorizationCode
  alias Noizu.MCP.Auth.Server.Store.Consent
  alias Noizu.MCP.Auth.Server.Store.RefreshToken

  @default_name __MODULE__
  @tables [:clients, :login_states, :codes, :refresh_tokens, :consents, :access_tokens]

  # ── lifecycle ────────────────────────────────────────────────────────────

  @doc "Start the store. `name:` also names the ETS tables, so several may coexist."
  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, @default_name)

    tables =
      Map.new(@tables, fn table ->
        {table,
         :ets.new(table_name(name, table), [
           :set,
           :public,
           :named_table,
           read_concurrency: true
         ])}
      end)

    {:ok, %{name: name, tables: tables}}
  end

  @doc "Drop every row. Test helper; never call it in production."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []), do: GenServer.call(server(opts), :reset)

  # ── clients ──────────────────────────────────────────────────────────────

  @impl Store
  def get_client(client_id, opts) do
    lookup(opts, :clients, client_id)
  end

  @impl Store
  def put_client(client, opts) do
    GenServer.call(server(opts), {:put, :clients, client.client_id, stamp(client)})
  end

  @impl Store
  def delete_client(client_id, opts) do
    GenServer.call(server(opts), {:delete, :clients, client_id})
  end

  # ── login state ──────────────────────────────────────────────────────────

  @impl Store
  def put_login_state(state, payload, ttl, opts) do
    record = %{payload: payload, expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)}

    case GenServer.call(server(opts), {:put, :login_states, Secret.token_hash(state), record}) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl Store
  def get_login_state(state, opts) do
    case lookup(opts, :login_states, Secret.token_hash(state)) do
      {:ok, %{payload: payload} = record} ->
        if expired?(record.expires_at), do: {:error, :not_found}, else: {:ok, payload}

      error ->
        error
    end
  end

  @impl Store
  def update_login_state(state, changes, opts) do
    GenServer.call(server(opts), {:update_login_state, Secret.token_hash(state), changes})
  end

  @impl Store
  def take_login_state(state, opts) do
    GenServer.call(server(opts), {:take_login_state, Secret.token_hash(state)})
  end

  # ── authorization codes ──────────────────────────────────────────────────

  @impl Store
  def put_authorization_code(%AuthorizationCode{} = code, opts) do
    record = %{code | code: nil, inserted_at: code.inserted_at || DateTime.utc_now()}

    case GenServer.call(server(opts), {:put, :codes, Secret.token_hash(code.code), record}) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl Store
  def take_authorization_code(code, opts) do
    GenServer.call(server(opts), {:take_code, Secret.token_hash(code)})
  end

  @impl Store
  def bind_authorization_code_family(code, family_id, opts) do
    GenServer.call(server(opts), {:bind_code_family, Secret.token_hash(code), family_id})
  end

  # ── refresh tokens ───────────────────────────────────────────────────────

  @impl Store
  def put_refresh_token(%RefreshToken{} = token, opts) do
    case GenServer.call(server(opts), {:put_refresh, Secret.token_hash(token.token), token}) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl Store
  def get_refresh_token(token, opts) do
    case lookup(opts, :refresh_tokens, Secret.token_hash(token)) do
      {:ok, record} -> if usable?(record), do: {:ok, record}, else: {:error, :not_found}
      error -> error
    end
  end

  @impl Store
  def rotate_refresh_token(old_token, %RefreshToken{} = new_token, opts) do
    GenServer.call(
      server(opts),
      {:rotate_refresh, Secret.token_hash(old_token), Secret.token_hash(new_token.token),
       new_token}
    )
  end

  @impl Store
  def revoke_refresh_token(token, opts) do
    GenServer.call(server(opts), {:revoke_refresh, Secret.token_hash(token)})
  end

  @impl Store
  def revoke_refresh_family(family_id, opts) do
    GenServer.call(server(opts), {:revoke_family, family_id})
  end

  @impl Store
  def revoke_subject_tokens(subject, client_id, opts) do
    GenServer.call(server(opts), {:revoke_subject, subject, client_id})
  end

  # ── consent ──────────────────────────────────────────────────────────────

  @impl Store
  def get_consent(subject, client_id, opts) do
    case lookup(opts, :consents, {subject, client_id}) do
      {:ok, %Consent{expires_at: nil} = consent} ->
        {:ok, consent}

      {:ok, %Consent{expires_at: expires} = consent} ->
        if expired?(expires), do: {:error, :not_found}, else: {:ok, consent}

      error ->
        error
    end
  end

  @impl Store
  def put_consent(%Consent{} = consent, opts) do
    record = %{consent | granted_at: consent.granted_at || DateTime.utc_now()}
    key = {consent.subject, consent.client_id}

    case GenServer.call(server(opts), {:put, :consents, key, record}) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl Store
  def revoke_consent(subject, client_id, opts) do
    GenServer.call(server(opts), {:delete, :consents, {subject, client_id}})
  end

  # ── access tokens ────────────────────────────────────────────────────────

  @impl Store
  def put_access_token(%AccessToken{} = token, opts) do
    record = %{token | jti: nil}

    case GenServer.call(
           server(opts),
           {:put, :access_tokens, Secret.token_hash(token.jti), record}
         ) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl Store
  def access_token_revoked?(jti, opts) do
    case lookup(opts, :access_tokens, Secret.token_hash(jti)) do
      {:ok, %AccessToken{revoked_at: nil}} -> false
      {:ok, %AccessToken{}} -> true
      # Untracked is not revoked — with `track_access_tokens: false` there is no
      # row for any token, and every request would otherwise 401.
      {:error, :not_found} -> false
    end
  end

  @impl Store
  def revoke_access_token(jti, opts) do
    GenServer.call(server(opts), {:revoke_access_token, Secret.token_hash(jti)})
  end

  @impl Store
  def purge_expired(now, opts) do
    GenServer.call(server(opts), {:purge, now})
  end

  # ── server ───────────────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:put, table, key, record}, _from, state) do
    :ets.insert(table(state, table), {key, record})
    {:reply, {:ok, record}, state}
  end

  def handle_call({:delete, table, key}, _from, state) do
    :ets.delete(table(state, table), key)
    {:reply, :ok, state}
  end

  def handle_call({:update_login_state, key, changes}, _from, state) do
    table = table(state, :login_states)

    case :ets.lookup(table, key) do
      [{^key, %{payload: payload} = record}] ->
        updated = %{record | payload: Map.merge(payload, changes)}
        :ets.insert(table, {key, updated})
        {:reply, {:ok, updated.payload}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:take_login_state, key}, _from, state) do
    # `:ets.take/2` is itself atomic; going through the process too means a
    # concurrent update cannot interleave with the read half.
    case :ets.take(table(state, :login_states), key) do
      [{^key, record}] ->
        if expired?(record.expires_at),
          do: {:reply, {:error, :not_found}, state},
          else: {:reply, {:ok, record.payload}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:take_code, hash}, _from, state) do
    table = table(state, :codes)

    reply =
      case :ets.lookup(table, hash) do
        [{^hash, %AuthorizationCode{used_at: nil} = code}] ->
          if expired?(code.expires_at) do
            {:error, :not_found}
          else
            # Mark used rather than delete: a replay has to be *visible*, and a
            # deleted row is indistinguishable from one that never existed.
            :ets.insert(table, {hash, %{code | used_at: DateTime.utc_now()}})
            {:ok, code}
          end

        [{^hash, %AuthorizationCode{} = used}] ->
          {:error, {:replayed, used}}

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:bind_code_family, hash, family_id}, _from, state) do
    table = table(state, :codes)

    case :ets.lookup(table, hash) do
      [{^hash, code}] ->
        :ets.insert(table, {hash, %{code | refresh_family_id: family_id}})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:put_refresh, hash, token}, _from, state) do
    record = %{
      token
      | token: nil,
        id: token.id || Store.generate_id(),
        inserted_at: token.inserted_at || DateTime.utc_now()
    }

    :ets.insert(table(state, :refresh_tokens), {hash, record})
    {:reply, {:ok, record}, state}
  end

  def handle_call({:rotate_refresh, old_hash, new_hash, new_token}, _from, state) do
    table = table(state, :refresh_tokens)

    reply =
      case :ets.lookup(table, old_hash) do
        [{^old_hash, %RefreshToken{} = old}] ->
          cond do
            not is_nil(old.revoked_at) ->
              {:error, :not_found}

            expired?(old.expires_at) ->
              {:error, :not_found}

            not is_nil(old.rotated_at) ->
              # Reuse detected. The caller revokes the family; we do not do it
              # here, so that the decision stays in one place.
              {:error, {:replayed, old}}

            true ->
              new_record = %{
                new_token
                | token: nil,
                  id: new_token.id || Store.generate_id(),
                  family_id: old.family_id,
                  family_expires_at: old.family_expires_at,
                  inserted_at: DateTime.utc_now()
              }

              :ets.insert(table, {new_hash, new_record})

              :ets.insert(
                table,
                {old_hash, %{old | rotated_at: DateTime.utc_now(), rotated_to: new_record.id}}
              )

              {:ok, old}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke_refresh, hash}, _from, state) do
    table = table(state, :refresh_tokens)

    case :ets.lookup(table, hash) do
      [{^hash, token}] -> :ets.insert(table, {hash, %{token | revoked_at: DateTime.utc_now()}})
      [] -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:revoke_family, family_id}, _from, state) do
    revoke_where(state, fn token -> token.family_id == family_id end)
    {:reply, :ok, state}
  end

  def handle_call({:revoke_subject, subject, client_id}, _from, state) do
    revoke_where(state, fn token ->
      token.subject == subject and (is_nil(client_id) or token.client_id == client_id)
    end)

    {:reply, :ok, state}
  end

  def handle_call({:revoke_access_token, hash}, _from, state) do
    table = table(state, :access_tokens)

    case :ets.lookup(table, hash) do
      [{^hash, token}] -> :ets.insert(table, {hash, %{token | revoked_at: DateTime.utc_now()}})
      [] -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:purge, now}, _from, state) do
    counts = %{
      login_states: purge(state, :login_states, & &1.expires_at, now),
      authorization_codes: purge(state, :codes, & &1.expires_at, now),
      refresh_tokens: purge(state, :refresh_tokens, & &1.expires_at, now),
      access_tokens: purge(state, :access_tokens, & &1.expires_at, now)
    }

    {:reply, {:ok, counts}, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(@tables, &:ets.delete_all_objects(table(state, &1)))
    {:reply, :ok, state}
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp revoke_where(state, predicate) do
    table = table(state, :refresh_tokens)
    now = DateTime.utc_now()

    :ets.foldl(
      fn {key, token}, acc ->
        if predicate.(token) and is_nil(token.revoked_at) do
          :ets.insert(table, {key, %{token | revoked_at: now}})
        end

        acc
      end,
      :ok,
      table
    )
  end

  defp purge(state, table_key, expires_fun, now) do
    table = table(state, table_key)

    :ets.foldl(
      fn {key, record}, count ->
        case expires_fun.(record) do
          nil ->
            count

          expires ->
            if DateTime.compare(now, expires) == :gt do
              :ets.delete(table, key)
              count + 1
            else
              count
            end
        end
      end,
      0,
      table
    )
  end

  defp lookup(opts, table_key, key) do
    case :ets.lookup(table_name(name(opts), table_key), key) do
      [{^key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  defp usable?(%RefreshToken{revoked_at: nil, rotated_at: nil} = token),
    do: not expired?(token.expires_at)

  defp usable?(%RefreshToken{}), do: false

  defp expired?(nil), do: false
  defp expired?(at), do: DateTime.compare(DateTime.utc_now(), at) != :lt

  defp stamp(client) do
    now = DateTime.utc_now()
    %{client | inserted_at: client.inserted_at || now, updated_at: now}
  end

  defp table(state, key), do: Map.fetch!(state.tables, key)
  defp table_name(name, table), do: Module.concat([name, Table, Macro.camelize(to_string(table))])
  defp name(opts), do: Keyword.get(opts, :name, @default_name)
  defp server(opts), do: name(opts)
end
