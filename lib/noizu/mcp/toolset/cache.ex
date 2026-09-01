defmodule Noizu.MCP.Toolset.Cache do
  @moduledoc """
  Optional ETS memoization of composed custom-toolset catalogs (PRD-3 §4.6).

  **Opt-in only** — `use Noizu.MCP.Server, toolset_cache: true | [ttl: ms]`
  and/or `%Noizu.MCP.Toolset.Custom{metadata: [cache: true]}` (or an explicit
  `cache:` compose opt). With the cache OFF the table is never created and no
  row is ever written (correctness first; the invalidation story completes in
  PRD-4 when Store writes call `invalidate/1` before `notify_changed/1`).

  Keys are `{toolset_id, principal_hash, catalog_version}`: the same toolset
  for the same principal over the same static+layer structure is a hit.
  `principal_hash/1` deliberately EXCLUDES claims/metadata — they don't
  affect layer selection, and folding them in makes keys unbounded.

  Never cached: validator errors and compose failures (D5 paths stay
  observable — they are always re-checked).

  Row shape note: the PRD sketches rows `{key, entries, version,
  inserted_at}`; the store carries the full composed map (entries + version +
  provenance + materialized specs) because `resolve/4` needs provenance
  (§4.3) and the effective spec (§4.4) on cache hits too.
  """

  alias Noizu.MCP.Auth.Principal

  @table :noizu_mcp_toolset_cache

  @type key ::
          {toolset_id :: String.t(), principal_hash :: binary(), catalog_version :: String.t()}
  @type composed :: %{
          entries: list(),
          version: String.t(),
          provenance: map(),
          specs: map()
        }

  @doc """
  Memoized composed catalog for `key`, or `:miss` (absent, TTL-expired — the
  row is dropped lazily — or the table never existed).
  """
  # ⟦𓋴𓄿𓎡𓉔𓅱⟧ get :: Memoized composed catalog for `key`, or `:miss` (absent, TTL-expired — the row is dropped lazily — or the table never existed).
  @spec get(key()) :: {:ok, composed()} | :miss
  def get(key) do
    case :ets.lookup(table(), key) do
      [{^key, composed, inserted_at, ttl}] ->
        if System.monotonic_time(:millisecond) - inserted_at > ttl do
          :ets.delete(@table, key)
          :miss
        else
          {:ok, composed}
        end

      [] ->
        :miss
    end
  catch
    # Table raced away between whereis and lookup — treat as a miss.
    :error, _ -> :miss
  end

  @doc "Memoize `composed` under `key`. `opts`: `[ttl: ms]` (default 60_000)."
  # ⟦𓊪𓅱𓏏⟧ put :: Memoize `composed` under `key`. `opts`: `[ttl: ms]` (default 60_000).
  @spec put(key(), composed(), keyword()) :: :ok
  def put(key, composed, opts \\ []) when is_map(composed) do
    ttl = Keyword.get(opts, :ttl, default_ttl())
    :ets.insert(table(), {key, composed, System.monotonic_time(:millisecond), ttl})
    :ok
  end

  @doc "Drop every row for `toolset_id` (PRD-4 Store writes call this before notify_changed/1)."
  # ⟦𓂝𓈖𓆑𓄿𓃭⟧ invalidate :: Drop every row for `toolset_id`.
  @spec invalidate(String.t()) :: :ok
  def invalidate(toolset_id) when is_binary(toolset_id) do
    # Never CREATES the table — invalidating a cache that was never on stays a no-op.
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ref ->
        :ets.match_delete(@table, {{toolset_id, :_, :_}, :_, :_, :_})
        :ok
    end
  end

  @doc """
  Stable hash of the principal's LAYER-RELEVANT identity: sha256 over
  `{subject, authenticator, granted_scopes}` (truncated 16 hex, matching the
  version fingerprints). Claims/metadata deliberately excluded — they never
  affect layer selection. `nil` (anonymous) hashes to a fixed value.
  """
  # ⟦𓊪𓂋𓆑⟧ principal_hash :: Stable hash of the principal's LAYER-RELEVANT identity: sha256 over.
  @spec principal_hash(Principal.t() | nil) :: binary()
  def principal_hash(nil), do: hash({nil, nil, nil})

  def principal_hash(%Principal{
        subject: subject,
        authenticator: authenticator,
        granted_scopes: scopes
      }),
      do: hash({subject, authenticator, scopes})

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp default_ttl, do: Application.get_env(:noizu_mcp, :toolset_cache_ttl, 60_000)

  # Lazily-created named public table; the catch makes the create race-safe
  # (the loser of a race keeps using the winner's table).
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        catch
          _kind, _reason -> :ok
        end

        @table

      ref ->
        ref
    end
  end
end
