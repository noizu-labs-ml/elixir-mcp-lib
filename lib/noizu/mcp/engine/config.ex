defmodule Noizu.MCP.Engine.Config do
  @moduledoc """
  Runtime configuration for `Noizu.MCP.Engine` (PRD-11 §4.1, D3): every option
  is read at CALL time from `Application.get_env(:noizu_mcp, :engine)` — no
  upstream, provider or policy is captured at compile time.

  | Key | Meaning | Default |
  |---|---|---|
  | `:persistence` | provider for the `servers` store | the ordinary `Noizu.MCP.Persistence` chain |
  | `:store_key` | persistence store key | `"engine_servers"` |
  | `:acl` | ACL provider governing federated tools and registry rows | `nil` (inert) |
  | `:static_servers` | list of upstream maps seeded at boot | `[]` |
  | `:connect_timeout_ms` | per-upstream handshake budget | `10_000` |
  | `:backoff` | `{initial_ms, max_ms, jitter}` | `{1_000, 60_000, 0.2}` |
  | `:refresh_interval_ms` | periodic catalog re-list per upstream | `300_000` |
  | `:passthrough_idle_ms` | per-principal pass-through session idle eviction | `60_000` |
  | `:secret_resolver` | `{module, function}` behind `secret:`/`infisical:` refs | `nil` |
  """

  @defaults [
    store_key: "engine_servers",
    persistence: nil,
    acl: nil,
    static_servers: [],
    connect_timeout_ms: 10_000,
    backoff: {1_000, 60_000, 0.2},
    refresh_interval_ms: 300_000,
    passthrough_idle_ms: 60_000,
    secret_resolver: nil
  ]

  @type backoff :: {non_neg_integer(), pos_integer(), float()}

  @doc "The full engine config with defaults applied."
  @spec all() :: keyword()
  def all, do: Application.get_env(:noizu_mcp, :engine, [])

  @doc "One engine config value at call time."
  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    case Keyword.fetch(all(), key) do
      {:ok, value} -> value
      :error -> Keyword.fetch!(@defaults, key)
    end
  end

  @doc """
  The resolved `{provider, opts}` persistence pair for the `servers` store: the
  engine's `:persistence` config when set, else the ordinary
  `Noizu.MCP.Persistence.resolved/2` chain (server stash, then application env,
  then `:memory`).
  """
  @spec persistence() :: {module(), keyword()}
  def persistence do
    case get(:persistence) do
      nil -> Noizu.MCP.Persistence.resolved(Noizu.MCP.Engine, [])
      value -> Noizu.MCP.Persistence.normalize(value) || {Noizu.MCP.Persistence.Memory, []}
    end
  end

  @doc "The persistence store key for the `servers` registry."
  @spec store_key() :: String.t()
  def store_key, do: get(:store_key)

  @doc """
  The pure backoff schedule: `min(initial * 2^attempt, max)` deflated by up to
  `jitter` (a `0.2` jitter draws delays in `[0.8x, x]`). Jitter only ever
  shortens a delay, so tests can assert upper bounds deterministically with
  `jitter: 0`.
  """
  @spec compute_backoff(backoff(), non_neg_integer()) :: non_neg_integer()
  def compute_backoff({initial, max, jitter}, attempt)
      when is_integer(attempt) and attempt >= 0 do
    base =
      (initial * 2 ** min(attempt, 24)) |> min(max)

    if jitter > 0.0 do
      trunc(base * (1.0 - jitter * :rand.uniform()))
    else
      base
    end
  end

  @doc "The configured backoff delay for `attempt` (reads config at call time)."
  @spec backoff_delay(non_neg_integer()) :: non_neg_integer()
  def backoff_delay(attempt), do: compute_backoff(get(:backoff), attempt)
end
