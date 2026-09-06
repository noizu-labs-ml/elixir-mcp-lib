defmodule Noizu.MCP.Engine.Tools.Detach do
  @moduledoc """
  `engine.detach` (PRD-11 §4.8): remove an upstream. A thin wrapper over the
  `servers` dataset's `delete/2` — one implementation with the SQL path (D1).
  """

  use Noizu.MCP.Server.Tool,
    name: "engine.detach",
    description: "Detach an upstream MCP server: drops its tools and its registry row."

  alias Noizu.MCP.Engine.Servers

  input do
    field :name, :string, required: true, description: "The upstream to detach"
  end

  @impl true
  def call(args, ctx) do
    quals = [%{column: "name", op: :eq, value: args[:name]}]

    case Servers.delete(quals, ctx) do
      {:ok, 0} ->
        # Same absent/error shape as an unknown tool — no existence oracle.
        {:error, "Unknown upstream: #{args[:name]}"}

      {:ok, _count} ->
        {:ok, %{"detached" => args[:name]}}

      {:error, _} = error ->
        error
    end
  end
end
