defmodule VfsDemoServer.Test do
  @moduledoc """
  Test/dev hook: mutate the demo tree programmatically, exactly as a remote
  client would. Mutations flow through the same `VfsDemoServer.Ops` path as
  wire requests, so versions, generations and pubsub events behave
  identically.

      VfsDemoServer.Test.mutate("/etc/dev/flag", :write, "on\\n")
      VfsDemoServer.Test.mutate("/notes/new.md", :create, "hello\\n")
      VfsDemoServer.Test.mutate("/notes/new.md", :create)       # directory
      VfsDemoServer.Test.mutate("/notes/new.md", :remove)
  """

  alias VfsDemoServer.{Backend, Ops}

  def mutate(path, op, data \\ nil) do
    ctx = %Noizu.MCP.Ctx{
      server: Backend,
      transport: :vfs_demo_test,
      assigns: %{auth_claims: %{"sub" => "test"}}
    }

    case op do
      :write ->
        Ops.dispatch("vfs/write", %{"path" => path, "data" => data}, ctx)

      :create when is_binary(data) ->
        Ops.dispatch("vfs/create", %{"path" => path, "data" => data}, ctx)

      :create ->
        Ops.dispatch("vfs/create", %{"path" => path}, ctx)

      :remove ->
        Ops.dispatch("vfs/remove", %{"path" => path}, ctx)
    end
  end
end
