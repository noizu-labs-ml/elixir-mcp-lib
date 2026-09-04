defmodule Noizu.MCP.Store do
  @moduledoc """
  The host write facade (PRD-4 §4.7): provider write → version bump →
  `Toolset.Cache.invalidate/1` → `notify_changed(:tools)` fan-out, in that
  order, with the persistence provider resolved LAZILY per call (§4.3 —
  explicit `persistence:`/`providers:` opts, then the per-server stash via
  `opts[:server]`, then Application env at call time, then `:memory`).

  The notify step is best-effort BY CONTRACT: the write already succeeded, so
  a crashing server module or a dead session is logged, never raised (D5).
  `server: :all` (default) enumerates `Noizu.MCP.Server.Supervisor.running_servers/0`.

  Hosts put grants to open a caller's surface, negotiations to open a consent
  gate, and toolset records to define DB-backed toolsets — the context pass
  (weight-200 layers) is the ONLY reader (D1); nothing here ever renders a
  record to the wire (D2).
  """

  alias Noizu.MCP.Persistence
  alias Noizu.MCP.Server.Supervisor
  alias Noizu.MCP.Toolset.Cache

  require Logger

  @kind_store [toolset: "toolsets", grant: "toolset_grants", negotiation: "toolset_negotiations"]

  @type kind :: :toolset | :grant | :negotiation

  @doc "The store key each kind maps to (§4.7)."
  # ⟦𓎡𓇋𓈖𓂧⟧ store_key :: The store key each kind maps to (§4.7).
  @spec store_key(kind()) :: {:ok, Persistence.store_key()} | {:error, {:unknown_kind, term()}}
  def store_key(kind) when is_atom(kind) do
    case Keyword.fetch(@kind_store, kind) do
      {:ok, store_key} -> {:ok, store_key}
      :error -> {:error, {:unknown_kind, kind}}
    end
  end

  def store_key(kind), do: {:error, {:unknown_kind, kind}}

  @doc """
  Upsert `record` by its id (`slug` for `:toolset`, `id` for grants and
  negotiations), then rotate the affected toolset's cache and notify live
  sessions.
  """
  # ⟦𓊪𓅱𓏏⟧ put :: Upsert `record` by its id.
  @spec put(kind(), map() | struct(), keyword()) :: :ok | {:error, term()}
  def put(kind, record, opts \\ []) do
    with {:ok, store_key} <- store_key(kind),
         {provider, popts} <- resolve(opts),
         {:ok, id} <- record_id(kind, record) do
      case provider.put(store_key, id, record, popts) do
        :ok ->
          # §4.7 normative order: write → (provider version bumped) →
          # invalidate → notify. Notify failures never propagate (D5).
          invalidate_for(kind, record)
          notify(opts)
          :ok

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error -> error
      provider_or_nil -> {:error, {:store_put_failed, provider_or_nil}}
    end
  end

  @doc "Fetch one record (`{:ok, record} | :error` — expiry applied by the store)."
  # ⟦𓎼𓅱𓏏⟧ get :: Fetch one record.
  @spec get(kind(), String.t(), keyword()) :: {:ok, map() | struct()} | :error | {:error, term()}
  def get(kind, id, opts \\ []) do
    with {:ok, store_key} <- store_key(kind),
         {provider, popts} <- resolve(opts) do
      provider.get(store_key, id, popts)
    else
      {:error, _} = error -> error
    end
  end

  @doc "List records for `kind` under an exact-match `filter` (inserted_at desc)."
  # ⟦𓃭𓇋𓋴𓏏⟧ list :: List records for `kind` under an exact-match `filter` (inserted_at desc).
  @spec list(kind(), map() | nil, keyword()) :: {:ok, [map() | struct()]} | {:error, term()}
  def list(kind, filter, opts \\ []) do
    with {:ok, store_key} <- store_key(kind),
         {provider, popts} <- resolve(opts) do
      provider.list(store_key, filter, popts)
    else
      {:error, _} = error -> error
    end
  end

  @doc "Delete by id (idempotent), rotating the affected toolset's cache and notifying."
  # ⟦𓂧𓅱𓃭𓅱𓏏⟧ delete :: Delete by id (idempotent), rotating the affected toolset's cache and notifying.
  @spec delete(kind(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(kind, id, opts \\ []) do
    with {:ok, store_key} <- store_key(kind),
         {provider, popts} <- resolve(opts) do
      case provider.delete(store_key, id, popts) do
        :ok ->
          # Grants/negotiations carry toolset_slug; a delete only knows the id,
          # so the cache is dropped for EVERY toolset — deletes are rare,
          # correctness is not.
          case kind do
            :toolset -> Cache.invalidate(id)
            _ -> invalidate_all()
          end

          notify(opts)
          :ok

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc "The store's monotonic version (`kind` or raw store_key) — the FR-4.11 rotation proof."
  # ⟦𓆑𓅱𓈖⟧ version :: The store's monotonic version.
  @spec version(kind() | Persistence.store_key(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def version(kind_or_key, opts \\ [])

  def version(kind, opts) when kind in [:toolset, :grant, :negotiation] do
    with {:ok, store_key} <- store_key(kind),
         {provider, popts} <- resolve(opts) do
      provider.version(store_key, popts)
    else
      {:error, _} = error -> error
    end
  end

  def version(store_key, opts) when is_binary(store_key) do
    case resolve(opts) do
      {provider, popts} -> provider.version(store_key, popts)
      nil -> {:error, :persistence_unresolved}
    end
  end

  def version(other, _opts), do: {:error, {:unknown_kind, other}}

  # ── internals ─────────────────────────────────────────────────────────────

  defp resolve(opts) do
    # Lazy re-resolution (§4.3): `opts[:server]` is what makes the per-server
    # stash reachable from a Store call; explicit opts still win.
    Persistence.resolved(opts[:server], opts)
  end

  defp record_id(:toolset, record), do: fetch_id(record, :slug)
  defp record_id(_kind, record), do: fetch_id(record, :id)

  defp fetch_id(record, field) do
    case Map.get(record, field) do
      nil -> {:error, {:missing_field, field}}
      id when is_binary(id) -> {:ok, id}
      other -> {:error, {:invalid_id, other}}
    end
  end

  # Cache keys are per-toolset (§4.7): a toolset record invalidates its own
  # slug; grant/negotiation records carry `toolset_slug`.
  defp invalidate_for(:toolset, record) do
    case Map.get(record, :slug) do
      slug when is_binary(slug) -> Cache.invalidate(slug)
      _ -> invalidate_all()
    end
  end

  defp invalidate_for(_kind, record) do
    case Map.get(record, :toolset_slug) do
      slug when is_binary(slug) -> Cache.invalidate(slug)
      _ -> invalidate_all()
    end
  end

  defp invalidate_all do
    # A single broad pass over the cache table; no-op when caching is off.
    case :ets.whereis(:noizu_mcp_toolset_cache) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(:noizu_mcp_toolset_cache)
    end

    :ok
  end

  # `server: :all` → every running server; a module or list of modules →
  # exactly those. Failures are logged, never raised — the WRITE succeeded.
  defp notify(opts) do
    servers =
      case opts[:server] do
        nil -> Supervisor.running_servers()
        :all -> Supervisor.running_servers()
        server -> List.wrap(server)
      end

    Enum.each(servers, fn server ->
      server.notify_changed(:tools)
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "Noizu.MCP.Store: notify_changed(:tools) failed — #{Exception.message(e)} " <>
          "(the write itself succeeded; D5)"
      )

      :ok
  end
end
