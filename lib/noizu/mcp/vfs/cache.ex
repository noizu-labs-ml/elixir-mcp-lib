defmodule Noizu.MCP.VFS.Cache do
  @moduledoc """
  TTL cache for VFS read results (`stat`, `list`, `read`), plus a per-backend
  generation counter used for invalidation.

  Mirrors NPL's toolset cache: a `:persistent_term` entry per backend holding
  `{generation, entries}` —

    * Entries are keyed `{kind, path}` and carry a TTL deadline. `read` results
      embed their version (`{:ok, content, version}`), so a caller can pass
      `expected_version:` to `get/4` to only accept a cached value whose
      version still matches what it saw in `stat`.
    * `bump_generation/1` (called by the dispatcher after every successful
      write/create/remove) increments the generation and drops every entry —
      no key bookkeeping on the write side.
    * TTL is the backstop for out-of-band backend writes that never bump:
      `Application.get_env(:noizu_mcp, :vfs_cache_ttl_ms)` (default 60s). The
      cache can be disabled entirely with
      `Application.put_env(:noizu_mcp, :vfs_cache_enabled, false)`.

  Concurrency note: the fill in `put/5` is a read-modify-write of the single
  term, so two concurrent misses can lose one fill. Harmless — the loser
  refills on its next read.
  """

  @base :noizu_mcp_vfs_cache
  @kind [:stat, :list, :read]

  @doc "Current generation for a backend. Monotonic; starts at 0."
  # ⟦𓆒⟧ generation
  @spec generation(module()) :: non_neg_integer()
  def generation(module), do: :persistent_term.get({@base, module}, {0, %{}}) |> elem(0)

  @doc "Invalidate every cached entry for `module` by advancing its generation."
  # ⟦𓆒⟧ bump_generation
  @spec bump_generation(module()) :: non_neg_integer()
  def bump_generation(module) do
    gen = generation(module) + 1
    :persistent_term.put({@base, module}, {gen, %{}})
    gen
  end

  @doc """
  Cached value for `{module, kind, path}`, or `nil`. Expired entries are
  erased and reported as misses. `:read` entries can be version-checked with
  the `:version` option.
  """
  # ⟦𓆒⟧ get
  @spec get(module(), :stat | :list | :read, String.t(), keyword()) :: term() | nil
  def get(module, kind, path, opts \\ []) when kind in @kind do
    if enabled?() do
      now = now_millis()

      case entries(module)[{kind, path}] do
        {expires_at, value} when expires_at > now ->
          if expected = opts[:version] do
            if read_version(value) == expected, do: value, else: nil
          else
            value
          end

        {_, _} ->
          :persistent_term.put(
            {@base, module},
            {generation(module), Map.delete(entries(module), {kind, path})}
          )

          nil

        nil ->
          nil
      end
    else
      nil
    end
  end

  @doc "Cache `value` for `{module, kind, path}` under the current generation."
  # ⟦𓆒⟧ put
  @spec put(module(), :stat | :list | :read, String.t(), term(), pos_integer()) :: :ok
  def put(module, kind, path, value, ttl_ms) when kind in @kind do
    if enabled?() do
      {gen, entries} = :persistent_term.get({@base, module}, {0, %{}})

      :persistent_term.put(
        {@base, module},
        {gen, Map.put(entries, {kind, path}, {now_millis() + ttl_ms, value})}
      )
    end

    :ok
  end

  @doc "Drop every entry for `module` (test helper; prefer `bump_generation/1`)."
  # ⟦𓆒⟧ purge
  @spec purge(module()) :: :ok
  def purge(module) do
    :persistent_term.put({@base, module}, {generation(module), %{}})
    :ok
  end

  defp entries(module),
    do: :persistent_term.get({@base, module}, {0, %{}}) |> elem(1)

  defp read_version({:ok, _content, version}) when is_integer(version), do: version
  defp read_version(_), do: nil

  defp enabled?, do: Application.get_env(:noizu_mcp, :vfs_cache_enabled, true)

  defp now_millis, do: System.monotonic_time(:millisecond)
end
