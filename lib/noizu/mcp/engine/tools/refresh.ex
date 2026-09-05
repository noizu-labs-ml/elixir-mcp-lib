defmodule Noizu.MCP.Engine.Tools.Refresh do
  @moduledoc """
  `engine.refresh` (PRD-11 §4.8): force a catalog re-list. A thin wrapper over
  the session supervision layer — the same path the periodic backstop and the
  upstream `list_changed` notifications take (D1).
  """

  use Noizu.MCP.Server.Tool,
    name: "engine.refresh",
    description:
      "Force an upstream catalog re-list. Omit name to refresh every attached upstream."

  alias Noizu.MCP.Engine.{Session, Supervisor}

  input do
    field :name, :string, description: "One upstream; all when omitted"
  end

  @impl true
  def call(args, _ctx) do
    sessions =
      Supervisor.sessions()
      |> Enum.filter(fn {key, _pid} -> is_binary(key) end)

    wanted =
      case args[:name] do
        nil -> sessions
        name -> Enum.filter(sessions, fn {key, _pid} -> key == name end)
      end

    statuses =
      case wanted do
        [] ->
          [%{"name" => args[:name] || "*", "status" => "disconnected", "status_detail" => nil}]

        _other ->
          Enum.map(wanted, fn {_key, pid} -> refresh_one(pid) end)
      end

    {:ok, %{"upstreams" => statuses}}
  end

  defp refresh_one(pid) do
    view = Session.refresh(pid)

    %{
      "name" => view[:name] || view.name,
      "status" => view[:status] || view.status,
      "status_detail" => view[:status_detail] || view.status_detail,
      "tool_count" => view[:tool_count] || view.tool_count
    }
  rescue
    _error -> %{"name" => nil, "status" => "disconnected", "status_detail" => nil}
  end
end
