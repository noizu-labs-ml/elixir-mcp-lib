defmodule Noizu.MCP.Engine.ACL do
  @moduledoc """
  The engine's ACL seam (PRD-11 §4.5): a delegating provider that resolves the
  REAL policy at CALL time from `Application.get_env(:noizu_mcp, :engine)[:acl]`
  (D3 — providers are runtime config, never compile captures).

  Shapes match the `acl:` registration vocabulary: `nil`/`:disabled` (inert —
  every check allows, the library's back-compat posture), `:deny_all`, a
  `Noizu.MCP.ACL.Provider` module, or `{provider, opts}`.

  The engine governs two resource kinds: `:tool` (federated entries, by their
  `<server>.<name>` prefixed wire names) and `:dataset` (the `servers`
  relation's own `sql/scan` authorization). A configured provider that does not
  list these kinds fails closed at the check boundary per PRD-2 §4.7.
  """

  @behaviour Noizu.MCP.ACL.Provider

  alias Noizu.MCP.ACL.Provider
  alias Noizu.MCP.Engine.Config

  @impl true
  def check(subject, resource, action, ctx, _opts) do
    case runtime() do
      nil ->
        :allow

      {provider, check_opts} ->
        Provider.check(provider, subject, resource, action, ctx, check_opts)
    end
  end

  @impl true
  def check_all(subject, resources, action, ctx, _opts) do
    case runtime() do
      nil ->
        Map.new(resources, &{&1.id, :allow})

      {provider, check_opts} ->
        Provider.check_all(provider, subject, resources, action, ctx, check_opts)
    end
  end

  @impl true
  def supported_kinds, do: [:tool, :dataset]

  defp runtime do
    case Config.get(:acl) do
      value when value in [nil, :disabled] ->
        nil

      :deny_all ->
        {Noizu.MCP.ACL.Providers.DenyAll, []}

      {provider, check_opts} when is_atom(provider) and is_list(check_opts) ->
        {provider, check_opts}

      provider when is_atom(provider) ->
        {provider, []}

      _other ->
        nil
    end
  end
end
