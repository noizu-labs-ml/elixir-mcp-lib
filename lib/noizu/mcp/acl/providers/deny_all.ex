defmodule Noizu.MCP.ACL.Providers.DenyAll do
  @moduledoc """
  `acl: :deny_all` — the built-in that denies everything (PRD-2 §4.6): every
  tool vanishes from the listing, every call resolves to the identical
  `invalid_params` error as an unknown tool, and `permissions/3` reports each
  entry `visible: false, callable: false, reason: {:acl, __MODULE__}`.
  """

  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  # ⟦𓃢𓎹𓋞𓄪⟧ check :: auto-generated pointer for public function check
  def check(_subject, _resource, _action, _ctx, _opts), do: :deny
end
