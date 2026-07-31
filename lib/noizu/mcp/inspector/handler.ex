defmodule Noizu.MCP.Inspector.Handler do
  @moduledoc """
  `Noizu.MCP.Client.Handler` for the inspector: server-initiated sampling and
  elicitation requests are parked in the inspector session and surfaced in the
  browser (Pending tab), blocking until a human answers. Roots come from the
  session's editable roots list.
  """

  @behaviour Noizu.MCP.Client.Handler

  alias Noizu.MCP.Inspector.Session

  @impl true
  # ⟦𓆏𓎪𓎫𓈷⟧ handle_sampling :: auto-generated pointer for public function handle_sampling
  def handle_sampling(params, session) do
    Session.park_pending(session, :sampling, params)
  end

  @impl true
  # ⟦𓄬𓏻𓎹𓀳⟧ handle_elicitation :: auto-generated pointer for public function handle_elicitation
  def handle_elicitation(params, session) do
    Session.park_pending(session, :elicitation, params)
  end

  @impl true
  # ⟦𓄏𓄅𓀤𓉓⟧ list_roots :: auto-generated pointer for public function list_roots
  def list_roots(session) do
    {:ok, Session.get_roots(session)}
  end
end
