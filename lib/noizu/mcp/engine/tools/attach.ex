defmodule Noizu.MCP.Engine.Tools.Attach do
  @moduledoc """
  `engine.attach` (PRD-11 §4.8): attach an upstream MCP server. A thin wrapper
  over the `servers` dataset's `insert/2` — ONE implementation, called by both
  the SQL path and this tool (D1).
  """

  use Noizu.MCP.Server.Tool,
    name: "engine.attach",
    description:
      "Attach an upstream MCP server. name becomes the tool namespace prefix; " <>
        "auth_ref is a credential REFERENCE (env:VAR, secret:<name>, " <>
        "infisical:<path>/<KEY>, or passthrough) — never an inline credential."

  alias Noizu.MCP.Engine.Servers

  input do
    field :name, :string, required: true, description: "Namespace prefix (^[a-z][a-z0-9_]{0,30}$)"
    field :transport, :enum, values: [:stdio, :http], required: true
    field :command, :string, description: "stdio only: the argv, shell-split"
    field :url, :string, description: "http only: the Streamable HTTP endpoint"
    field :auth_ref, :string, description: "Credential reference"
    field :enabled, :boolean, default: true
  end

  @impl true
  def call(args, ctx) do
    row = %{
      "name" => args[:name],
      "transport" => to_string(args[:transport]),
      "command" => args[:command],
      "url" => args[:url],
      "auth_ref" => args[:auth_ref],
      "enabled" => if(is_nil(args[:enabled]), do: true, else: args[:enabled])
    }

    case Servers.insert([row], ctx) do
      {:ok, [inserted]} -> {:ok, attached_result(inserted)}
      {:error, _} = error -> error
    end
  end

  defp attached_result(row) do
    %{
      "attached" => row["name"],
      "status" => row["status"],
      "status_detail" => row["status_detail"]
    }
  end
end
