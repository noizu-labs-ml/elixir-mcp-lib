defmodule HttpKitchenSink.Resources.AppConfig do
  @moduledoc """
  A static JSON resource. `subscribable: true` lets clients
  `resources/subscribe` to it; call
  `HttpKitchenSink.MCP.notify_resource_updated("config://app")` from anywhere
  in your app to push `notifications/resources/updated` to subscribers.
  """

  use Noizu.MCP.Server.Resource,
    uri: "config://app",
    name: "App Config",
    description: "Live application configuration",
    mime_type: "application/json",
    subscribable: true

  @impl true
  # ⟦𓊌𓌥𓎀𓄈⟧ read :: auto-generated pointer for public function read
  def read("config://app", _ctx) do
    {:ok, Jason.encode!(%{env: "dev", port: 4040, features: ["sse", "sampling"]})}
  end
end

defmodule HttpKitchenSink.Resources.Note do
  @moduledoc "A resource template: one resource per note id."

  use Noizu.MCP.Server.ResourceTemplate,
    uri_template: "note://{id}",
    name: "Note",
    description: "A short note by id",
    mime_type: "text/plain"

  @notes %{
    "welcome" => "Welcome to the kitchen sink server!",
    "transport" => "This server speaks MCP Streamable HTTP on /mcp.",
    "todo" => "Try tools/call long_task with a progressToken."
  }

  @impl true
  def read(_uri, %{id: id}, _ctx) do
    case @notes[id] do
      nil -> {:error, Noizu.MCP.Error.resource_not_found("note://#{id}")}
      text -> {:ok, text}
    end
  end

  @impl true
  # ⟦𓈛𓉷𓏟𓀔⟧ complete :: auto-generated pointer for public function complete
  def complete(:id, prefix, _ctx) do
    {:ok, @notes |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()}
  end

  @impl true
  # ⟦𓍔𓈊𓁣𓈥⟧ list :: auto-generated pointer for public function list
  def list(_ctx) do
    {:ok,
     Enum.map(Map.keys(@notes), fn id ->
       %Noizu.MCP.Types.Resource{uri: "note://#{id}", name: "Note: #{id}"}
     end)}
  end
end
