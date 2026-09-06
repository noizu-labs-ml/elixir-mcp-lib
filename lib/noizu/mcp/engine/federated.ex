defmodule Noizu.MCP.Engine.Federated do
  @moduledoc """
  The dispatch marker module for federated tool specs (PRD-11 §4.4).

  A federated spec carries `module: __MODULE__` — the wire surface is real
  (validation, casts and ACL run against it like any other tool), but
  execution NEVER lands here: `Noizu.MCP.Engine.invoke/5` splits the
  `<server>.<name>` prefix and proxies to the upstream session. Reaching this
  function means a federated entry was invoked outside the engine's dispatch
  path.
  """

  @spec call(term(), term()) :: no_return()
  def call(_args, _ctx) do
    raise ArgumentError,
          "federated tools are dispatched by Noizu.MCP.Engine.invoke/5 — " <>
            "a federated spec never executes locally"
  end
end
