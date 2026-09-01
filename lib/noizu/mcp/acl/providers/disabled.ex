defmodule Noizu.MCP.ACL.Providers.Disabled do
  @moduledoc """
  `acl: :disabled` — the built-in that allows everything (PRD-2 §4.6): the
  authorization posture of an unconfigured server, available as an explicit
  provider. The default resolution maps `:disabled` straight to "no provider"
  (nil ⇒ inert fast-path), so this module mainly serves hosts that want to
  name the posture, and tests that exercise the explicit-provider path.
  """

  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  # ⟦𓂁𓊢𓋗𓆣⟧ check :: auto-generated pointer for public function check
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow
end
