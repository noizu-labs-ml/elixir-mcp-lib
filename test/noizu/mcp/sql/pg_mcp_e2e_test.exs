defmodule Noizu.MCP.SQL.PgMcpE2ETest do
  @moduledoc """
  PRD-10 §4.3–§4.4: the whole pg_mcp series proven through a real Postgres
  running the layered extension image, against a real `Noizu.MCP.Engine` on a
  real Bandit listener with real stdio fixture upstreams.

  The nineteen assertions E1–E19 are the point of the series: identity
  (E9/E10, ADR-004), install-once federation (E15, ADR-007), and parity
  between every SQL surface and its MCP method. A Rust-side stub cannot prove
  any of this; nothing short of this stack can.

  Running it (pg/docker/README.md has the long form):

      docker compose -f pg/docker/e2e-compose.yaml up -d --build
      PG_MCP_URL=ecto://postgres:postgres@localhost:15432/pg_mcp_e2e \\
        mix test --only pg_mcp

  `PG_MCP_URL` unset → the whole suite reports skipped and exits 0 (AC-10.5).
  The suite tears down everything it creates and tolerates a dirty database
  from a previous run (FR-10.9): setup drops and recreates the extension and
  every schema it owns before importing.
  """

  use ExUnit.Case, async: false

  @moduletag :pg_mcp

  # Read at compile time — the same invocation that sets PG_MCP_URL compiles
  # this file with it set. A `--only pg_mcp` run without the variable then
  # reports every test skipped (with the reason) and exits 0 (AC-10.5).
  if System.get_env("PG_MCP_URL") in [nil, ""] do
    @moduletag skip:
                 "PG_MCP_URL is unset — start the layered image first: docker compose -f pg/docker/e2e-compose.yaml up -d --build"
  end

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Fixtures.Engine, as: EngineFixture
  alias Noizu.MCP.Fixtures.PgE2E
  alias Noizu.MCP.Fixtures.Server, as: FixtureServer

  @alice_claims %{"sub" => "alice"}

  # ── harness boot ────────────────────────────────────────────────────────────

  setup_all do
    case System.get_env("PG_MCP_URL") do
      # Unreachable when the suite is skipped via the compile-time tag above.
      nil ->
        :ok

      url ->
        {:ok, live_setup(url)}
    end
  end

  defp live_setup(url) do
    boot = PgE2E.boot()

    admin = start_conn!(url)
    bob = start_conn!(url, username: "e2e_bob")
    mallory = start_conn!(url, username: "e2e_mallory")

    on_exit(fn ->
      EngineFixture.reset!()
    end)

    # ── dirty-database hygiene (FR-10.9): drop everything this suite owns ──
    q!(admin, "DROP EXTENSION IF EXISTS pg_mcp CASCADE")

    for schema <- ~w(engine engine_union generic alpha github extra mcp_local) do
      q!(admin, "DROP SCHEMA IF EXISTS #{schema} CASCADE")
    end

    for role <- ~w(e2e_bob e2e_mallory) do
      q!(admin, """
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
          CREATE ROLE #{role} LOGIN;
        END IF;
      END $$;
      """)
    end

    q!(admin, "CREATE EXTENSION pg_mcp")

    # ── ONE foreign server for the engine (FR-10.13, ADR-007) ──────────────
    engine_url = "http://#{PgE2E.callback_host()}:#{boot.engine_port}/mcp"

    q!(admin, """
    CREATE SERVER engine FOREIGN DATA WRAPPER mcp_fdw
      OPTIONS (url '#{engine_url}', timeout_ms '20000')
    """)

    q!(admin, "CREATE USER MAPPING FOR CURRENT_USER SERVER engine OPTIONS (token 'alice-token')")
    q!(admin, "CREATE USER MAPPING FOR e2e_bob SERVER engine OPTIONS (token 'bob-token')")

    q!(
      admin,
      "CREATE USER MAPPING FOR e2e_mallory SERVER engine OPTIONS (token 'bad-token')"
    )

    # The all_upstreams layout (§4.3): one schema per upstream + engine's own.
    # Import options ride `mcp.import` (the SPI executor), not the IMPORT
    # FOREIGN SCHEMA statement — that statement's OPTIONS are the per-TABLE
    # options (upstream, cache_ttl_ms) the read path consumes afterwards.
    # mcp.import creates the target schema itself (per_tool emits plain
    # CREATE SCHEMA per tool's schema).
    # Target schema is `mcp_local` deliberately: all_upstreams derives an
    # upstream schema for EVERY prefixed tools/list name, including the
    # engine's own `engine.attach`/`detach`/`refresh` — so a schema named
    # `engine` comes into existence as the engine-local tools' slice, and the
    # INTO schema must not collide with it.
    q!(admin, "CREATE SCHEMA mcp_local")

    q!(admin, """
    SELECT mcp.import('engine', 'mcp_local', '{"all_upstreams": true}')
    """)

    # Per-tool objects, per schema. The combined all_upstreams + per_tool
    # import would re-emit plain CREATE SCHEMA for schemas this import just
    # created, so the per-tool pass runs per schema instead — same objects,
    # and `generate_functions` is exactly what the runbook tells operators to
    # re-run after an attach.
    for schema <- ~w(alpha github engine) do
      q!(admin, "SELECT * FROM mcp.generate_functions('engine', '#{schema}')")
    end

    # And the default (union) layout from the SAME server — still one
    # registration; this is where E1–E12's `mcp.tools` parity lives
    # (AC-7.14's two faces).
    q!(admin, "CREATE SCHEMA engine_union")
    q!(admin, "IMPORT FOREIGN SCHEMA mcp FROM SERVER engine INTO engine_union")

    # ── E19: generic mode, a bare fixture server alongside the engine ──────
    fixture_url = "http://#{PgE2E.callback_host()}:#{boot.generic_port}/fixture"

    q!(admin, """
    CREATE SERVER generic FOREIGN DATA WRAPPER mcp_fdw
      OPTIONS (url '#{fixture_url}', timeout_ms '20000')
    """)

    q!(
      admin,
      "CREATE USER MAPPING FOR CURRENT_USER SERVER generic OPTIONS (token 'alice-token')"
    )

    q!(admin, "CREATE SCHEMA generic")
    q!(admin, "IMPORT FOREIGN SCHEMA mcp FROM SERVER generic INTO generic")

    # Roles reach the SQL surface so E9/E10 exercise the TOKEN, not Postgres
    # privileges (a 42501 from a missing grant would prove nothing).
    for role <- ~w(e2e_bob e2e_mallory) do
      q!(admin, "GRANT USAGE ON FOREIGN SERVER engine, generic TO #{role}")
      q!(admin, "GRANT USAGE ON SCHEMA engine_union, generic TO #{role}")
      q!(admin, "GRANT SELECT ON ALL TABLES IN SCHEMA engine_union, generic TO #{role}")
    end

    %{
      admin: admin,
      bob: bob,
      mallory: mallory
    }
  end

  # Direct (in-process) clients are created PER TEST: the Test transport
  # pins its response sink to the calling process, and setup_all's process
  # does not deliver to individual tests.
  defp engine_client, do: connect(Engine)
  defp bare_client, do: connect(FixtureServer)

  defp start_conn!(url, overrides \\ []) do
    opts =
      url
      |> PgE2E.conn_opts()
      |> Keyword.merge(overrides)

    case Postgrex.start_link(opts) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "Postgrex start failed: #{inspect(reason)}"
    end
  end

  # ── parity with tools/list (E1, E2) ─────────────────────────────────────────

  test "E1: mcp.tools count equals tools/list as the same principal", ctx do
    {:ok, tools} = list_tools(engine_client(), claims: @alice_claims)
    assert count(ctx.admin, "SELECT count(*) FROM engine_union.tools") == length(tools)
  end

  test "E2: mcp.tools matches tools/list field-for-field, input_schema jsonb-equal", ctx do
    {:ok, tools} = list_tools(engine_client(), claims: @alice_claims)

    sql_tools =
      rows(ctx.admin, """
      SELECT name, description, input_schema FROM engine_union.tools ORDER BY name
      """)

    by_name = Map.new(tools, &{&1.name, &1})

    for [name, description, input_schema] <- sql_tools do
      tool = Map.fetch!(by_name, name)
      assert description == tool.description, "description drift on #{name}"
      assert input_schema == tool.input_schema, "input_schema drift on #{name}"
    end

    assert length(sql_tools) == map_size(by_name)
  end

  # ── invocation (E3, E4, E5, E6) ─────────────────────────────────────────────

  test "E3: INSERT INTO tool_calls RETURNING equals a direct tools/call", ctx do
    {:ok, result} =
      call_tool(engine_client(), "alpha.echo", %{"message" => "hi"}, claims: @alice_claims)

    direct_text = text_of(result)

    [[content]] =
      rows(ctx.admin, """
      INSERT INTO engine_union.tool_calls (tool, arguments)
      VALUES ('alpha.echo', '{"message":"hi"}')
      RETURNING content
      """)

    assert sql_content_text(content) == direct_text
  end

  test "E4: a failing tool beside a succeeding one is a row, and the statement commits", ctx do
    [[tool_a, is_error_a], [tool_b, is_error_b]] =
      rows(ctx.admin, """
      INSERT INTO engine_union.tool_calls (tool, arguments)
      VALUES ('alpha.fail', '{}'), ('alpha.echo', '{"message":"ok"}')
      RETURNING tool, is_error
      """)

    assert {tool_a, is_error_a} == {"alpha.fail", true}
    assert {tool_b, is_error_b} == {"alpha.echo", false}
  end

  test "E5: per-tool WHERE invocation returns typed rows equal to tools/call", ctx do
    [[message, content, is_error]] =
      rows(ctx.admin, """
      SELECT message, content, is_error FROM alpha.tool_alpha_greet WHERE message = 'hi'
      """)

    assert message == "hi"
    refute is_error
    # greet = "hello " <> message — the row IS the call.
    assert content |> sql_content_text() == "hello hi"

    {:ok, result} =
      call_tool(engine_client(), "alpha.greet", %{"message" => "hi"}, claims: @alice_claims)

    assert text_of(result) == "hello hi"
  end

  test "E6: SELECT on a non-read-only per-tool table raises 0A000; the INSERT form works", ctx do
    assert_sqlstate(ctx.admin, "SELECT * FROM alpha.tool_alpha_echo WHERE message = 'x'", "0A000")

    [[content, is_error]] =
      rows(ctx.admin, """
      INSERT INTO alpha.tool_alpha_echo (message) VALUES ('x') RETURNING content, is_error
      """)

    refute is_error
    assert sql_content_text(content) == "x"
  end

  # ── read-through parity (E7, E8) — generic mode's bare fixture server ───────

  test "E7: prompt_messages equals prompts/get", ctx do
    {:ok, prompt} = get_prompt(bare_client(), "dynamic")
    messages = prompt.messages

    sql_messages =
      rows(ctx.admin, """
      SELECT idx, role, text FROM generic.prompt_messages
      WHERE prompt = 'dynamic' ORDER BY idx
      """)

    assert length(sql_messages) == length(messages)

    for {{idx, role, text}, wire} <- Enum.zip(sql_messages, messages) do
      assert to_string(role) == to_string(wire.role)
      assert text == message_text(wire.content)
      assert is_integer(idx)
    end
  end

  test "E8: resource_contents equals resources/read", ctx do
    {:ok, contents} = read_resource(bare_client(), "config://app")
    wire = hd(contents)

    [[uri, mime_type, text]] =
      rows(ctx.admin, """
      SELECT uri, mime_type, text FROM generic.resource_contents WHERE uri = 'config://app'
      """)

    assert uri == "config://app"
    assert mime_type == wire.mime_type
    assert text == wire.text
  end

  # ── identity (E9, E10) — the series' go/no-go (ADR-004) ────────────────────

  test "E9: a bad token yields 42501 and no principal was synthesized", ctx do
    assert_sqlstate(ctx.mallory, "SELECT count(*) FROM engine_union.tools", "42501")

    # The verifier saw the request and REJECTED it: no %Principal{} was ever
    # built server-side — not even an anonymous one.
    assert PgE2E.PrincipalLog.last("bad-token") == {:error, :invalid_token}
  end

  test "E10: two USER MAPPINGs see two different tool sets", ctx do
    alice_names = tool_names(ctx.admin)
    bob_names = tool_names(ctx.bob)

    alice_set = MapSet.new(alice_names)
    bob_set = MapSet.new(bob_names)

    # bob is denied the whole github upstream: absent for him, present for her.
    assert "github.echo" in alice_names
    refute "github.echo" in bob_names
    refute Enum.any?(bob_names, &String.starts_with?(&1, "github."))

    # bob keeps the allowed upstreams.
    assert "alpha.echo" in bob_names
    assert "alpha.greet" in bob_names

    # AP-P17: neither set is a superset BY ACCIDENT — bob's is a strict
    # subset of alice's, and they are not equal.
    assert MapSet.subset?(bob_set, alice_set)
    refute MapSet.equal?(bob_set, alice_set)
  end

  # ── qual honesty (E11) ─────────────────────────────────────────────────────

  test "E11: quals are re-checked — a scan returns exactly what the qual asks for", ctx do
    # The live-protocol half of AP-P12: the qual-constrained read-through scan
    # returns exactly the requested resource — rows outside the qual never
    # leak into the result, whatever the upstream lists. (The deliberate
    # lying-stub half is pinned server-side by the Rust e2e battery, where the
    # fixture CAN be instructed to lie; a real upstream cannot.)
    [[uri, text]] =
      rows(ctx.admin, """
      SELECT uri, text FROM generic.resource_contents
      WHERE uri = 'config://app'
      """)

    assert uri == "config://app"
    assert text == ~s({"env":"test"})
  end

  # ── refresh + regeneration (E12, E13) ──────────────────────────────────────

  test "E12+E13: a server-side tool change is reflected in mcp.tools after refresh, and generate_functions picks it up",
       ctx do
    refute "alpha.late_tool" in tool_names(ctx.admin)
    refute relation_exists?(ctx.admin, "alpha", "tool_alpha_late_tool")

    # emit_change makes the upstream emit notifications/tools/list_changed
    # and add late_tool to its catalog.
    q!(ctx.admin, """
    INSERT INTO engine_union.tool_calls (tool, arguments)
    VALUES ('alpha.emit_change', '{}')
    """)

    assert q!(ctx.admin, "SELECT mcp.refresh('engine')").rows == [[true]]

    # The engine observes the upstream's list_changed asynchronously; force
    # the engine session's re-list and drop the FDW cache until the union
    # reflects it.
    wait_until(
      fn ->
        q!(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.refresh', '{}')")
        q!(ctx.admin, "SELECT mcp.refresh('engine')")
        "alpha.late_tool" in tool_names(ctx.admin)
      end,
      100
    )

    assert "alpha.late_tool" in tool_names(ctx.admin)

    # Regeneration is destructive-in-scope and re-reads fresh (D1): the new
    # tool's objects appear, the existing ones survive.
    q!(ctx.admin, "SELECT * FROM mcp.generate_functions('engine', 'alpha')")

    assert relation_exists?(ctx.admin, "alpha", "tool_alpha_late_tool")
    assert relation_exists?(ctx.admin, "alpha", "tool_alpha_greet")
  end

  # ── durability (E14) ───────────────────────────────────────────────────────

  @tag :tmp_dir
  test "E14: pg_dump/pg_restore round-trips servers, mappings and foreign tables", ctx do
    container = System.get_env("PG_MCP_CONTAINER", "pg_mcp_e2e_postgres")
    admin = ctx.admin

    q!(admin, "DROP DATABASE IF EXISTS pg_mcp_e2e_restore")

    dump_file =
      Path.join(System.tmp_dir!(), "pg_mcp_e2e-#{System.unique_integer([:positive])}.dump")

    on_exit(fn -> File.rm(dump_file) end)

    File.write!(
      dump_file,
      docker!(container, ["pg_dump", "-U", "postgres", "-p", "15432", "-Fc", "pg_mcp_e2e"])
    )

    {_, 0} = System.cmd("docker", ["cp", dump_file, "#{container}:/tmp/pg_mcp_e2e.dump"])

    q!(admin, "CREATE DATABASE pg_mcp_e2e_restore")
    # Roles are cluster-global (bob/mallory already exist), so the restored
    # CREATE USER MAPPING statements resolve.
    docker!(container, [
      "pg_restore",
      "-p",
      "15432",
      "-U",
      "postgres",
      "--no-owner",
      "-d",
      "pg_mcp_e2e_restore",
      "/tmp/pg_mcp_e2e.dump"
    ])

    restored = start_conn!(pg_mcp_url!(), database: "pg_mcp_e2e_restore")

    on_exit(fn ->
      try do
        Postgrex.close(restored)
      rescue
        _ -> :ok
      end
    end)

    # Servers survived.
    servers = rows(restored, "SELECT srvname FROM pg_foreign_server ORDER BY 1")
    assert servers == [["engine"], ["generic"]]

    # Mappings survived — all three identities.
    mappings =
      rows(restored, "SELECT usename, srvname FROM pg_user_mappings ORDER BY 1, 2")
      |> Enum.map(&List.to_tuple/1)

    assert {"e2e_bob", "engine"} in mappings
    assert {"e2e_mallory", "engine"} in mappings
    assert {"postgres", "generic"} in mappings

    # Foreign tables survived, in the right schemas.
    for {schema, table} <- [
          {"mcp_local", "tools"},
          {"engine_union", "tool_calls"},
          {"alpha", "tools"},
          {"alpha", "tool_alpha_greet"},
          {"github", "tools"},
          {"generic", "prompt_messages"}
        ] do
      assert relation_exists?(restored, schema, table), "lost #{schema}.#{table}"
    end

    # And the restored objects still WORK against the same extension .so.
    assert "alpha.greet" in tool_names(restored)
  end

  # ── install once (E15, E16, E17, E18) — ADR-007's central claim ────────────

  test "E15+E17: install once — attach, use, detach, all through the ONE foreign server", ctx do
    refute "extra.echo" in tool_names(ctx.admin)

    command = Noizu.MCP.Fixtures.Engine.command(name: "extra", tools: ["echo"])

    attach_args =
      Jason.encode!(%{
        "name" => "extra",
        "transport" => "stdio",
        "command" => command,
        "enabled" => true
      })

    # The whole attach is SQL, against the ONE existing foreign server:
    # no CREATE SERVER, no USER MAPPING, no Postgres restart. (The engine
    # exposes its registry through its MCP surface; `engine.servers` as a
    # writable SQL dataset rides sql/modify, outside the frozen ten-table
    # FDW registry.)
    [[attach_result]] =
      rows(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.attach', '#{attach_args}')")

    # A rejected attach surfaces as an isError payload, not an exception.
    refute attach_result["isError"], "engine.attach rejected: #{inspect(attach_result)}"

    wait_until(
      fn ->
        # engine.refresh makes the ENGINE's HTTP session re-list its
        # upstreams (its catalog is per-session and does not track attach
        # notifications); mcp.refresh then drops the FDW's catalog cache so
        # the next scan re-fetches.
        q!(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.refresh', '{}')")
        q!(ctx.admin, "SELECT mcp.refresh('engine')")
        "extra.echo" in tool_names(ctx.admin)
      end,
      100
    )

    # One empty schema is the only DDL beyond the runbook calls; the
    # generated objects themselves are still never hand-written.
    q!(ctx.admin, "CREATE SCHEMA IF NOT EXISTS extra")
    q!(ctx.admin, "SELECT * FROM mcp.generate_functions('engine', 'extra')")

    # The upstream's tools appear — and are callable from SQL through the
    # same single server.
    assert "extra.echo" in tool_names(ctx.admin)
    assert relation_exists?(ctx.admin, "extra", "tool_extra_echo")

    [[content, is_error]] =
      rows(ctx.admin, """
      INSERT INTO extra.tool_extra_echo (message) VALUES ('installed-once')
      RETURNING content, is_error
      """)

    refute is_error
    assert sql_content_text(content) == "installed-once"

    # ── E17: detach removes the tools AND the generated objects ────────────
    q!(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.detach', '{\"name\":\"extra\"}')")

    wait_until(
      fn ->
        q!(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.refresh', '{}')")
        q!(ctx.admin, "SELECT mcp.refresh('engine')")
        "extra.echo" not in tool_names(ctx.admin)
      end,
      100
    )

    # Align the engine session once more, then let regeneration drop the
    # detached upstream's generated objects (it owns exactly what it created).
    q!(ctx.admin, "SELECT mcp.call_tool('engine', 'engine.refresh', '{}')")
    q!(ctx.admin, "SELECT mcp.refresh('engine')")
    q!(ctx.admin, "SELECT * FROM mcp.generate_functions('engine', 'extra')")

    refute "extra.echo" in tool_names(ctx.admin)
    refute relation_exists?(ctx.admin, "extra", "tool_extra_echo")

    # The others are untouched.
    assert relation_exists?(ctx.admin, "alpha", "tool_alpha_greet")
    assert "alpha.echo" in tool_names(ctx.admin)
  end

  test "E16: a broken upstream reads error while every other row reads ready, and mcp.tools is unaffected",
       ctx do
    # Engine-level: the servers relation is the health surface.
    {:ok, scan} = sql_scan(engine_client(), "servers", quals: [])
    assert %{"columns" => columns, "rows" => server_rows} = scan

    by_name = servers_by_name(columns, server_rows)

    assert by_name["broken"]["status"] == "error"
    assert by_name["alpha"]["status"] == "ready"
    assert by_name["github"]["status"] == "ready"

    # SQL-level (AP-P15): the broken upstream contributes NO tools and does
    # not reduce anyone else's.
    names = tool_names(ctx.admin)
    refute Enum.any?(names, &String.starts_with?(&1, "broken."))
    assert "alpha.echo" in names
    assert "github.echo" in names
  end

  test "E18: per-upstream schemas — one per upstream plus the engine's own, no redundant prefixes",
       ctx do
    schemas =
      rows(ctx.admin, """
      SELECT nspname FROM pg_namespace
      WHERE nspname IN ('engine', 'alpha', 'github', 'mcp_local') ORDER BY 1
      """)

    assert schemas == [["alpha"], ["engine"], ["github"], ["mcp_local"]]

    # NOTE: per-tool objects in this database are generated with the
    # single-schema mode (prefixed identifiers) because the per_upstream_schema
    # mode refuses occupied upstream schemas by design. The no-redundant-prefix
    # property is asserted where the all_upstreams layout provides it: the
    # per-upstream catalog.

    github_tools = rows(ctx.admin, "SELECT name FROM github.tools ORDER BY name")
    assert github_tools == [["echo"], ["token"]]

    # While the union view keeps the fully-qualified name.
    assert "github.echo" in tool_names(ctx.admin)
  end

  # ── generic mode still works (E19) ─────────────────────────────────────────

  test "E19: a second foreign server over a bare fixture server behaves per PRD-7, alongside the engine",
       ctx do
    {:ok, tools} = list_tools(bare_client())

    assert count(ctx.admin, "SELECT count(*) FROM generic.tools") == length(tools)

    [[content, is_error]] =
      rows(ctx.admin, """
      INSERT INTO generic.tool_calls (tool, arguments)
      VALUES ('echo', '{"message":"generic"}')
      RETURNING content, is_error
      """)

    refute is_error
    assert sql_content_text(content) == "generic"

    # Both registrations coexist in one database.
    assert "alpha.echo" in tool_names(ctx.admin)
    assert count(ctx.admin, "SELECT count(*) FROM pg_foreign_server") >= 2
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      assert attempts > 0, "condition not met within the wait window: #{servers_diag()}"
      Process.sleep(100)
      wait_until(fun, attempts - 1)
    end
  end

  # Failure diagnostics: the engine's servers relation + the SQL union.
  defp servers_diag do
    servers =
      case sql_scan(engine_client(), "servers", quals: []) do
        {:ok, %{"columns" => cols, "rows" => rws}} ->
          Enum.map(rws, fn r -> cols |> Enum.zip(r) |> Map.new() end)

        other ->
          other
      end

    "servers=#{inspect(servers, limit: :infinity)}"
  end

  defp q!(conn, sql), do: Postgrex.query!(conn, sql, [])

  defp rows(conn, sql), do: q!(conn, sql).rows
  defp count(conn, sql), do: rows(conn, sql) |> hd() |> hd()

  defp tool_names(conn),
    do: rows(conn, "SELECT name FROM engine_union.tools ORDER BY name") |> List.flatten()

  defp relation_exists?(conn, schema, table) do
    count(conn, """
    SELECT count(*) FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '#{schema}' AND c.relname = '#{table}'
    """) > 0
  end

  defp assert_sqlstate(conn, sql, sqlstate) do
    try do
      q!(conn, sql)
      flunk("expected SQLSTATE #{sqlstate} from: #{sql}")
    rescue
      e in Postgrex.Error ->
        got = e.postgres && Map.get(e.postgres, :pg_code)
        assert got == sqlstate, "expected #{sqlstate}, got #{inspect(got)}: #{e.message}"
    end
  end

  # Direct-client tool results carry atom content types; SQL jsonb is plain maps.
  defp text_of(%{content: content}) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{type: :text, text: t} -> t
      _ -> nil
    end)
  end

  defp sql_content_text(content) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{"type" => "text", "text" => t} -> t
      _ -> nil
    end)
  end

  defp message_text(content) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{type: :text, text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> nil
    end)
  end

  defp servers_by_name(columns, rows) do
    idx = Map.new(Enum.with_index(columns))

    Map.new(rows, fn row ->
      name = Enum.at(row, idx["name"])
      {name, row |> Enum.with_index() |> Map.new(fn {v, i} -> {Enum.at(columns, i), v} end)}
    end)
  end

  defp pg_mcp_url!, do: System.get_env("PG_MCP_URL")

  defp docker!(container, args) do
    case System.cmd("docker", ["exec", container | args]) do
      {out, 0} -> out
      {out, code} -> raise "docker exec #{container} #{hd(args)} failed (#{code}): #{out}"
    end
  end
end
