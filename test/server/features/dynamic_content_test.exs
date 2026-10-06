defmodule Noizu.MCP.DynamicContentFixtures do
  @moduledoc false

  defmodule StaticGreeting do
    @moduledoc false
    use Noizu.MCP.Server.Resource,
      uri: "static://greeting",
      name: "Static Greeting",
      mime_type: "text/plain"

    @impl true
    def read("static://greeting", _ctx), do: {:ok, "static hello"}
  end

  defmodule StaticWelcome do
    @moduledoc false
    use Noizu.MCP.Server.Prompt,
      name: "static_welcome",
      description: "A static prompt"

    arguments do
      arg :who, required: true, description: "Who to greet"
    end

    @impl true
    def get(%{"who" => who}, _ctx), do: {:ok, [Noizu.MCP.Types.PromptMessage.user("Hello #{who} (static)")]}
  end

  defmodule Server do
    @moduledoc false
    use Noizu.MCP.Server, name: "dc-test", version: "1.0.0"

    resource StaticGreeting
    prompt StaticWelcome

    content {Noizu.MCP.VFS.Fixture.Memory, []},
      resources: "/resources",
      prompts: "/prompts",
      uri_scheme: "content"
  end

  defmodule ScopedServer do
    @moduledoc false
    use Noizu.MCP.Server, name: "dc-scoped-test", version: "1.0.0"

    content {Noizu.MCP.VFS.Fixture.Memory, []},
      resources: "/resources",
      prompts: "/prompts",
      write_scope: "content:write"
  end

  defmodule ReadOnlyServer do
    @moduledoc false
    use Noizu.MCP.Server, name: "dc-readonly-test", version: "1.0.0"

    content {Noizu.MCP.VFS.Fixture.Memory, [read_only: true]}, resources: "/resources"
  end

  defmodule BridgeWinsServer do
    @moduledoc false
    use Noizu.MCP.Server, name: "dc-bridge-test", version: "1.0.0"

    # Same-named backend opt — the bridge opt must win.
    content {Noizu.MCP.VFS.Fixture.Memory, [resources: "/backend"]}, resources: "/bridge"
  end

  @tree %{
    "/" => :dir,
    "/resources" => :dir,
    "/resources/guide.md" => "# Guide\n\nSecond paragraph.\n",
    "/resources/data.bin" => <<1, 2, 3>>,
    "/prompts" => :dir,
    "/prompts/greet.json" =>
      ~s({"name":"greet","description":"Greet someone","arguments":[{"name":"who","description":"target","required":true}],"messages":[{"role":"user","content":"Hello {{who}}!"}]}),
    "/prompts/broken.json" => "{not json"
  }

  def tree, do: @tree
end

defmodule Noizu.MCP.DynamicContentTest do
  use ExUnit.Case, async: false

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.VFS, as: VFSOps
  alias Noizu.MCP.VFS.Cache
  alias Noizu.MCP.DynamicContentFixtures, as: F

  setup do
    # The cache is keyed on the backend module (persistent_term) — drop any
    # state a previous test left behind before seeding a fresh tree.
    Cache.purge(Noizu.MCP.VFS.Fixture.Memory)
    ctx = Noizu.MCP.VFS.Fixture.Memory.seed(F.tree())
    %{ctx: ctx}
  end

  # ── resources ─────────────────────────────────────────────────────────────

  test "resources/list merges static registrations with content-mount files", %{ctx: ctx} do
    {:ok, resources, nil} = F.Server.handle_list_resources(nil, ctx)

    uris = Enum.map(resources, & &1.uri)
    assert "static://greeting" in uris
    assert "content://guide.md" in uris
    assert "content://data.bin" in uris

    # Static entries keep their position in front of the dynamic ones.
    assert hd(uris) == "static://greeting"

    guide = Enum.find(resources, &(&1.uri == "content://guide.md"))
    assert guide.mime_type == "text/markdown"
    assert guide.description == "# Guide"
    assert guide.name == "guide.md"
  end

  test "mime falls back to the extension map for backends without mime_type/2", %{ctx: ctx} do
    {:ok, resources, _} = F.Server.handle_list_resources(nil, ctx)
    bin = Enum.find(resources, &(&1.uri == "content://data.bin"))
    assert bin.mime_type == "application/octet-stream"
  end

  test "resources/read serves content-scheme URIs off the mount", %{ctx: ctx} do
    [contents] = F.Server.handle_read_resource("content://guide.md", ctx)
    assert contents.text == "# Guide\n\nSecond paragraph.\n"
    assert contents.mime_type == "text/markdown"
    assert contents.uri == "content://guide.md"
  end

  test "resources/read passes unknown URIs through to the static registry", %{ctx: ctx} do
    [contents] = F.Server.handle_read_resource("static://greeting", ctx)
    assert contents.text == "static hello"

    assert {:error, %Error{}} = F.Server.handle_read_resource("content://nope.md", ctx)
  end

  test "resources/subscribe: content URIs are subscribable, unknown ones are not", %{ctx: ctx} do
    assert F.Server.handle_subscribe("content://guide.md", ctx) == :ok
    assert {:error, %Error{}} = F.Server.handle_subscribe("content://nope.md", ctx)
  end

  # ── prompts ───────────────────────────────────────────────────────────────

  test "prompts/list merges static prompts with content-mount JSON, skipping invalid files", %{
    ctx: ctx
  } do
    {:ok, prompts, nil} = F.Server.handle_list_prompts(nil, ctx)

    names = Enum.map(prompts, & &1.name)
    assert "static_welcome" in names
    assert "greet" in names
    # broken.json is skipped — one bad file must not hide the others.
    refute "broken" in names

    greet = Enum.find(prompts, &(&1.name == "greet"))
    assert greet.description == "Greet someone"
    assert [%Noizu.MCP.Types.Prompt.Argument{name: "who", required: true}] = greet.arguments
  end

  test "prompts/get renders a content-mount prompt with argument substitution", %{ctx: ctx} do
    {:ok, messages, description: description} = F.Server.handle_get_prompt("greet", %{"who" => "world"}, ctx)

    assert [%Noizu.MCP.Types.PromptMessage{role: :user, content: content}] = messages
    assert content.text == "Hello world!"
    assert description == "Greet someone"
  end

  test "prompts/get reports missing required arguments", %{ctx: ctx} do
    assert {:error, %Error{} = error} = F.Server.handle_get_prompt("greet", %{}, ctx)
    assert error.message =~ "Missing required arguments"
  end

  test "prompts/get on invalid JSON reports an error instead of crashing", %{ctx: ctx} do
    assert {:error, %Error{}} = F.Server.handle_get_prompt("broken", %{}, ctx)
  end

  test "prompts/get passes static prompts to their modules first", %{ctx: ctx} do
    {:ok, messages, _} = F.Server.handle_get_prompt("static_welcome", %{"who" => "world"}, ctx)
    assert [%Noizu.MCP.Types.PromptMessage{content: content}] = messages
    assert content.text == "Hello world (static)"
  end

  # ── CRUD round-trip through vfs/* + change fan-out ─────────────────────────

  test "vfs create/write/remove CRUDs prompts and fans out notifications", %{ctx: ctx} do
    start_supervised!(F.Server)

    # A fake session in the server's registry receives the notification casts
    # (GenServer.cast envelopes arrive as `{: "$gen_cast", msg}`).
    {:ok, _} = Registry.register(Module.concat(F.Server, Registry), {:session, "fake-session"}, nil)

    echo = ~s({"name":"echo","description":"Echo prompt","arguments":[],"messages":[{"role":"user","content":"echo!"}]})

    # create → advertised
    assert {:ok, _} = VFSOps.vfs_create(F.Server, %{"path" => "/prompts/echo.json", "data" => echo}, ctx)
    {:ok, prompts, _} = F.Server.handle_list_prompts(nil, ctx)
    assert "echo" in Enum.map(prompts, & &1.name)
    assert_receive {:"$gen_cast", {:notify_changed, :prompts}}

    # get works off the new file
    {:ok, messages, _} = F.Server.handle_get_prompt("echo", %{}, ctx)
    assert [%Noizu.MCP.Types.PromptMessage{content: content}] = messages
    assert content.text == "echo!"

    # write → updated + resource fan-out for the resources prefix
    updated = String.replace(echo, "Echo prompt", "Echo prompt v2")

    assert {:ok, _} =
             VFSOps.vfs_write(F.Server, %{"path" => "/prompts/echo.json", "data" => updated}, ctx)

    {:ok, _messages, description: description} = F.Server.handle_get_prompt("echo", %{}, ctx)
    assert description == "Echo prompt v2"
    assert_receive {:"$gen_cast", {:notify_changed, :prompts}}

    assert {:ok, _} =
             VFSOps.vfs_write(F.Server, %{"path" => "/resources/guide.md", "data" => "# Rewritten\n"}, ctx)

    assert_receive {:"$gen_cast", {:notify_resource_updated, "content://guide.md"}}
    assert_receive {:"$gen_cast", {:notify_changed, :resources}}

    # remove → gone from the listing
    assert {:ok, _} = VFSOps.vfs_remove(F.Server, %{"path" => "/prompts/echo.json"}, ctx)
    {:ok, prompts, _} = F.Server.handle_list_prompts(nil, ctx)
    refute "echo" in Enum.map(prompts, & &1.name)
    assert_receive {:"$gen_cast", {:notify_changed, :prompts}}

    # A mutation outside every content prefix never reaches the mount on a
    # content-only server (no plain vfs registration to fall back to), so it
    # fans nothing out either.
    assert {:error, %Error{}} = VFSOps.vfs_create(F.Server, %{"path" => "/free.txt", "data" => "x"}, ctx)
    refute_receive {:"$gen_cast", {:notify_changed, _}}
    refute_receive {:"$gen_cast", {:notify_resource_updated, _}}
  end

  # ── write gating ──────────────────────────────────────────────────────────

  test "write_scope: mutations under content prefixes are denied without the scope", %{ctx: ctx} do
    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/new.json", "data" => "{}"}, ctx)

    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_write(F.ScopedServer, %{"path" => "/resources/guide.md", "data" => "x"}, ctx)

    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_remove(F.ScopedServer, %{"path" => "/resources/guide.md"}, ctx)
  end

  test "write_scope: the scope (exact or glob) unlocks mutations, reads stay open", %{ctx: ctx} do
    exact = Ctx.assign(ctx, :auth_claims, %{"scopes" => ["content:write"]})
    assert {:ok, _} = VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/new.json", "data" => "{}"}, exact)

    glob = Ctx.assign(ctx, :auth_claims, %{"scp" => ["content:*"]})
    assert {:ok, _} = VFSOps.vfs_write(F.ScopedServer, %{"path" => "/resources/guide.md", "data" => "x"}, glob)

    wrong = Ctx.assign(ctx, :auth_claims, %{"scopes" => ["other:write"]})

    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_remove(F.ScopedServer, %{"path" => "/resources/guide.md"}, wrong)

    # Reads never require the scope.
    [_contents] = F.ScopedServer.handle_read_resource("content://guide.md", ctx)

    # Paths outside every content prefix are not gated — but on a content-only
    # server they route to no backend at all, so they are still rejected.
    assert {:error, %Error{}} = VFSOps.vfs_create(F.ScopedServer, %{"path" => "/free.txt", "data" => "x"}, ctx)
  end

  test "content-only server: undeclared prefixes are never served, scope or not", %{ctx: ctx} do
    assert {:error, %Error{}} = VFSOps.vfs_write(F.Server, %{"path" => "/somewhere/else.md", "data" => "x"}, ctx)
    assert {:error, %Error{}} = VFSOps.vfs_remove(F.Server, %{"path" => "/free.txt"}, ctx)

    scoped = Ctx.assign(ctx, :auth_claims, %{"scope" => "content:write"})

    assert {:error, %Error{}} =
             VFSOps.vfs_create(F.ScopedServer, %{"path" => "/undeclared/new.txt", "data" => "x"}, scoped)

    # Declared prefixes still route and stat.
    assert {:ok, _} = VFSOps.vfs_stat(F.Server, %{"path" => "/resources/guide.md"}, ctx)
  end

  test "write_scope: canonical scope claim shapes satisfy the gate", %{ctx: ctx} do
    # Space-joined binary `scope` — what the JWT and Basic verifiers stamp.
    joined = Ctx.assign(ctx, :auth_claims, %{"scope" => "openid content:write"})
    assert {:ok, _} = VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/joined.json", "data" => "{}"}, joined)

    # Binary `scp`.
    scp = Ctx.assign(ctx, :auth_claims, %{"scp" => "content:write"})
    assert {:ok, _} = VFSOps.vfs_write(F.ScopedServer, %{"path" => "/resources/guide.md", "data" => "x"}, scp)

    # List `scopes` (the list form `JWTVerifier.scopes/1` consumes; a binary
    # `scope` is the space-joined shape above, never a list).
    listed = Ctx.assign(ctx, :auth_claims, %{"scopes" => ["content:write"]})
    assert {:ok, _} = VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/listed.json", "data" => "{}"}, listed)

    # Mismatched claims are still :eacces.
    wrong = Ctx.assign(ctx, :auth_claims, %{"scope" => "openid email"})

    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/no.json", "data" => "{}"}, wrong)
  end

  test "write_scope: BasicVerifier-stamped claims pass, bare * grants do not", %{ctx: ctx} do
    users = %{"alice" => Noizu.MCP.Auth.Server.Secret.token_hash("pw")}

    {:ok, claims} =
      Noizu.MCP.Auth.BasicVerifier.verify("Basic " <> Base.encode64("alice:pw"), %{},
        users: users,
        scopes: ["content:write"]
      )

    assert claims["scope"] == "content:write"

    assert {:ok, _} =
             VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/basic.json", "data" => "{}"}, Ctx.assign(ctx, :auth_claims, claims))

    # A superuser `"*"` grant covers nothing but a write_scope of `"*"`.
    {:ok, star} =
      Noizu.MCP.Auth.BasicVerifier.verify("Basic " <> Base.encode64("alice:pw"), %{},
        users: users,
        scopes: ["*"]
      )

    assert {:error, %Error{code: -32040}} =
             VFSOps.vfs_create(F.ScopedServer, %{"path" => "/prompts/star.json", "data" => "{}"}, Ctx.assign(ctx, :auth_claims, star))
  end

  test "bridge opts win over same-named backend opts" do
    assert [{_, opts}] = F.BridgeWinsServer.__mcp__(:content)
    assert opts[:resources] == "/bridge"
  end

  # ── capabilities ──────────────────────────────────────────────────────────

  test "read-only content registration never advertises vfs_write", _ctx do
    caps = F.Server.__mcp__(:capabilities)
    assert caps["vfs"] == true
    assert caps["vfs_write"] == true
    assert caps["resources"]["subscribe"] == true
    assert caps["prompts"]["listChanged"] == true

    ro_caps = F.ReadOnlyServer.__mcp__(:capabilities)
    assert ro_caps["vfs"] == true
    refute Map.has_key?(ro_caps, "vfs_write")
  end

  test "content registration exposes the backend on __mcp__(:vfs) for vfs/* tooling", %{
    ctx: ctx
  } do
    assert [{Noizu.MCP.VFS.Fixture.Memory, _}] = F.Server.__mcp__(:vfs)
    assert {:ok, _} = VFSOps.vfs_stat(F.Server, %{"path" => "/resources/guide.md"}, ctx)
  end
end
