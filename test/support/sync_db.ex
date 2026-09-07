defmodule Noizu.MCP.Test.SyncDB do
  @moduledoc "Disposable PostgreSQL integration support. Never connects to shared databases."

  def urls do
    {System.fetch_env!("MCP_SYNC_TEST_DATABASE_URL"),
     System.fetch_env!("MCP_SYNC_SOURCE_DATABASE_URL")}
  end

  def connection_spec(url, username, id) do
    %{id: id, start: {Postgrex, :start_link, [connection_opts(url, username)]}, shutdown: 5000}
  end

  def repo_spec(url, username, module),
    do: module.child_spec(connection_opts(url, username) ++ [log: false])

  defp connection_opts(url, username) do
    uri = URI.parse(url)
    ensure_isolated!(uri)
    original_username = uri.userinfo |> String.split(":", parts: 2) |> hd()

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path, "/"),
      username: username || original_username,
      pool_size: 1,
      parameters: [application_name: "noizu_sync_integration"],
      backoff_type: :stop
    ]
  end

  def install!(url) do
    uri = URI.parse(url)
    ensure_isolated!(uri)
    {:ok, probe} = Postgrex.start_link(connection_opts(url, nil))

    installed =
      try do
        scalar!(probe, "SELECT to_regnamespace('mcp_sync') IS NOT NULL")
      after
        GenServer.stop(probe)
      end

    unless installed, do: install_schema!(uri)
  end

  defp install_schema!(uri) do
    sql = Path.expand("../../priv/sql/noizu_mcp_sync.sql", __DIR__)
    unless File.regular?(sql), do: raise("Sync migration SQL is not available: #{sql}")

    {output, status} =
      System.cmd(
        System.get_env("MCP_SYNC_PSQL", "psql"),
        ["--no-psqlrc", "--quiet", "--set", "ON_ERROR_STOP=1", "--file", sql],
        env: [
          {"PGHOST", uri.host},
          {"PGPORT", to_string(uri.port || 5432)},
          {"PGUSER", uri.userinfo},
          {"PGDATABASE", String.trim_leading(uri.path, "/")}
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("Sync migration failed: " <> String.slice(output, -4000, 4000))
  end

  def query!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params)

  def scalar!(conn, sql, params \\ []) do
    %{rows: [[value]]} = query!(conn, sql, params)
    value
  end

  def bootstrap_roles!(conn) do
    for {role, parent} <- [
          {"sync_test_a", "mcp_sync_client"},
          {"sync_test_b", "mcp_sync_client"},
          {"sync_test_worker", "mcp_sync_worker"}
        ] do
      query!(
        conn,
        "DO $body$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN CREATE ROLE #{role} LOGIN; END IF; END $body$"
      )

      query!(conn, "GRANT #{parent} TO #{role}")
    end
  end

  def binding!(conn, id, role, principal \\ "a") do
    query!(
      conn,
      """
      INSERT INTO mcp_sync.bindings
        (id, tenant_id, source_id, principal_id, relation, app_role, access_mode, capabilities)
      VALUES ($1::text::uuid, 'tenant-test', 'source-test', $2, 'notes', $3::name, 'read_write', $4::jsonb)
      """,
      [
        id,
        principal,
        role,
        %{
          "version" => 1,
          "changeRetentionSeconds" => 604_800,
          "conditionalWrites" => true,
          "idempotency" => true,
          "changes" => true,
          "snapshot" => "consistent",
          "idempotencyRetentionSeconds" => 604_800
        }
      ]
    )
  end

  defp ensure_isolated!(uri) do
    unless System.get_env("MCP_SYNC_ISOLATED") == "1" and uri.host == "127.0.0.1" and
             uri.path in ["/noizu_mcp_sync_cache_test", "/noizu_mcp_sync_source_test"] and
             uri.userinfo == "sync_admin" do
      raise "Sync tests require scripts/test_sync.sh and its disposable local databases"
    end
  end
end

defmodule Noizu.MCP.Test.SyncCacheRepo do
  use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
end

defmodule Noizu.MCP.Test.SyncSourceRepo do
  use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
end

defmodule Noizu.MCP.Test.SyncAppRepo do
  use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
end
