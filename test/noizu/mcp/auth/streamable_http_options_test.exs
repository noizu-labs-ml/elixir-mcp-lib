defmodule Noizu.MCP.Auth.StreamableHTTPOptionsTest do
  @moduledoc """
  The transport plug's new authorization and CORS options. Everything here is
  something a browser MCP client needs and cannot work around: the challenge it
  is allowed to read, the scope it is told to ask for, and a resource metadata
  URL that matches the mount it is actually talking to.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn

  alias Noizu.MCP.Auth.WWWAuthenticate
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  setup_all do
    Noizu.MCP.Test.ensure_server_started(Fixtures.Server)
  end

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "options_test", "version" => "1.0.0"}
    }
  }

  defp post(opts, headers \\ [], path \\ "/") do
    conn(:post, path, Jason.encode!(@initialize))
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    end)
    |> MCPPlug.call(opts)
  end

  defp challenge(conn) do
    [header] = get_resp_header(conn, "www-authenticate")
    WWWAuthenticate.parse(header)
  end

  describe "401 challenge conformance" do
    @opts MCPPlug.init(
            server: Fixtures.Server,
            auth: [
              verifier: {Fixtures.TokenVerifier, []},
              resource_metadata: "https://x/.well-known/oauth-protected-resource/mcp",
              scope: "mcp"
            ]
          )

    test "a missing credential gets no error code — nothing is wrong yet" do
      conn = post(@opts)
      assert conn.status == 401

      params = challenge(conn).params
      refute Map.has_key?(params, "error")
      assert params["resource_metadata"] == "https://x/.well-known/oauth-protected-resource/mcp"
      assert params["scope"] == "mcp"
    end

    test "an invalid token keeps error=invalid_token" do
      conn = post(@opts, [{"authorization", "Bearer nope"}])
      assert conn.status == 401
      assert challenge(conn).params["error"] == "invalid_token"
      assert challenge(conn).params["scope"] == "mcp"
    end

    test "insufficient scope reports the scope the verifier asked for, not the configured one" do
      conn = post(@opts, [{"authorization", "Bearer lowscope-token"}])
      assert conn.status == 403

      params = challenge(conn).params
      assert params["error"] == "insufficient_scope"
      assert params["scope"] == "mcp:admin"
      assert params["resource_metadata"] =~ "oauth-protected-resource"
    end

    test "the configured scope is advertised when the verifier names none" do
      opts =
        MCPPlug.init(
          server: Fixtures.Server,
          auth: [
            verifier: {Fixtures.OptionsVerifier, []},
            resource_metadata: "https://x/prm",
            scope: "mcp"
          ]
        )

      conn = post(opts, [{"authorization", "Bearer noscope-token"}])
      assert conn.status == 403
      assert challenge(conn).params["scope"] == "mcp"
    end

    test "with no scope configured the challenge simply omits it" do
      opts =
        MCPPlug.init(
          server: Fixtures.Server,
          auth: [verifier: {Fixtures.TokenVerifier, []}, resource_metadata: "https://x/prm"]
        )

      refute Map.has_key?(challenge(post(opts)).params, "scope")
    end
  end

  describe "resource_metadata derivation" do
    def prm_url(domain),
      do: "https://app.example.com/.well-known/oauth-protected-resource/mcp/#{domain}"

    def prm_from_conn(conn), do: "https://#{conn.host}/prm-from-conn"

    defp metadata_for(resource_metadata, conn_fun \\ & &1) do
      opts =
        MCPPlug.init(
          server: Fixtures.Server,
          auth: [verifier: {Fixtures.TokenVerifier, []}, resource_metadata: resource_metadata]
        )

      conn(:post, "/", Jason.encode!(@initialize))
      |> put_req_header("content-type", "application/json")
      |> conn_fun.()
      |> MCPPlug.call(opts)
      |> challenge()
      |> Map.fetch!(:params)
      |> Map.get("resource_metadata")
    end

    test "a binary is used verbatim" do
      assert metadata_for("https://x/prm") == "https://x/prm"
    end

    test "{module, function, args} is applied without the conn" do
      # This is the form that keeps a compile-time `forward` from baking a
      # build-time value into the release.
      assert metadata_for({__MODULE__, :prm_url, ["learning"]}) ==
               "https://app.example.com/.well-known/oauth-protected-resource/mcp/learning"
    end

    test "{module, function} receives the conn" do
      assert metadata_for({__MODULE__, :prm_from_conn}) =~ "/prm-from-conn"
    end

    test "a 1-arity fun receives the conn" do
      assert metadata_for(fn conn -> "https://#{conn.host}/fun-prm" end) =~ "/fun-prm"
    end

    test ":derive builds the RFC 9728 path-inserted URL from the mount path" do
      derived =
        metadata_for(:derive, fn conn ->
          # What Phoenix's `forward "/mcp/learning"` leaves behind.
          %{
            conn
            | script_name: ["mcp", "learning"],
              host: "app.example.com",
              port: 443,
              scheme: :https
          }
        end)

      assert derived ==
               "https://app.example.com/.well-known/oauth-protected-resource/mcp/learning"
    end

    test ":derive keeps a non-default port and omits a default one" do
      assert metadata_for(:derive, fn conn ->
               %{conn | script_name: ["mcp"], host: "localhost", port: 4000, scheme: :http}
             end) == "http://localhost:4000/.well-known/oauth-protected-resource/mcp"

      assert metadata_for(:derive, fn conn ->
               %{conn | script_name: [], host: "x.example.com", port: 80, scheme: :http}
             end) == "http://x.example.com/.well-known/oauth-protected-resource"
    end

    test "omitting resource_metadata omits it from the challenge" do
      opts =
        MCPPlug.init(server: Fixtures.Server, auth: [verifier: {Fixtures.TokenVerifier, []}])

      refute Map.has_key?(challenge(post(opts)).params, "resource_metadata")
    end
  end

  describe "origins: :mcp_clients" do
    @opts MCPPlug.init(server: Fixtures.Server, origins: :mcp_clients)

    test "allows the browser MCP hosts" do
      for origin <- MCPPlug.mcp_client_origins() do
        refute post(@opts, [{"origin", origin}]).status == 403
      end
    end

    test "allows localhost, for a local inspector" do
      refute post(@opts, [{"origin", "http://localhost:6274"}]).status == 403
      refute post(@opts, [{"origin", "http://127.0.0.1:6274"}]).status == 403
    end

    test "allows a request with no Origin at all — that is every desktop client" do
      refute post(@opts).status == 403
    end

    test "refuses anything else, including a suffix look-alike" do
      for origin <- [
            "https://evil.example",
            "https://claude.ai.evil.example",
            "https://evil-claude.ai",
            "http://claude.ai"
          ] do
        assert post(@opts, [{"origin", origin}]).status == 403
      end
    end

    test "mcp_client_origins/0 is https-only and extendable" do
      assert Enum.all?(MCPPlug.mcp_client_origins(), &String.starts_with?(&1, "https://"))

      extended =
        MCPPlug.init(
          server: Fixtures.Server,
          origins: ["https://mine" | MCPPlug.mcp_client_origins()]
        )

      refute post(extended, [{"origin", "https://mine"}]).status == 403
      refute post(extended, [{"origin", "https://claude.ai"}]).status == 403
    end
  end

  describe "CORS" do
    @opts MCPPlug.init(
            server: Fixtures.Server,
            origins: :mcp_clients,
            cors: true,
            auth: [verifier: {Fixtures.TokenVerifier, []}, resource_metadata: "https://x/prm"]
          )

    test "the 401 exposes WWW-Authenticate — without it a browser client cannot start OAuth" do
      conn = post(@opts, [{"origin", "https://claude.ai"}])
      assert conn.status == 401

      assert [exposed] = get_resp_header(conn, "access-control-expose-headers")
      assert exposed =~ "WWW-Authenticate"
      assert exposed =~ "Mcp-Session-Id"
      assert exposed =~ "Mcp-Protocol-Version"
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://claude.ai"]
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "a successful response carries the same expose header" do
      conn =
        post(@opts, [{"origin", "https://claude.ai"}, {"authorization", "Bearer valid-token"}])

      assert conn.status == 200
      assert [_] = get_resp_header(conn, "mcp-session-id")
      assert [exposed] = get_resp_header(conn, "access-control-expose-headers")
      assert exposed =~ "Mcp-Session-Id"
    end

    test "OPTIONS preflight is 204, before authentication" do
      conn =
        conn(:options, "/", "")
        |> put_req_header("origin", "https://claude.ai")
        |> put_req_header("access-control-request-headers", "mcp-session-id, authorization")
        |> MCPPlug.call(@opts)

      assert conn.status == 204
      # No challenge: a preflight carries no credentials by design.
      assert get_resp_header(conn, "www-authenticate") == []
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://claude.ai"]

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET, POST, DELETE, OPTIONS"
             ]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "mcp-session-id, authorization"
             ]

      assert get_resp_header(conn, "access-control-max-age") == ["600"]
    end

    test "a preflight without a requested-headers list falls back to the configured allowlist" do
      conn =
        conn(:options, "/", "")
        |> put_req_header("origin", "https://claude.ai")
        |> MCPPlug.call(@opts)

      assert [headers] = get_resp_header(conn, "access-control-allow-headers")
      assert headers =~ "mcp-protocol-version"
      assert headers =~ "last-event-id"
    end

    test "a preflight from a disallowed origin is 403, not 204" do
      conn =
        conn(:options, "/", "")
        |> put_req_header("origin", "https://evil.example")
        |> MCPPlug.call(@opts)

      assert conn.status == 403
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "cors options are configurable" do
      opts =
        MCPPlug.init(
          server: Fixtures.Server,
          cors: [allow_headers: "authorization", max_age: 60]
        )

      conn =
        conn(:options, "/", "")
        |> put_req_header("origin", "http://localhost")
        |> MCPPlug.call(opts)

      assert get_resp_header(conn, "access-control-allow-headers") == ["authorization"]
      assert get_resp_header(conn, "access-control-max-age") == ["60"]
    end

    test "with cors disabled OPTIONS is 405 and no CORS headers are set" do
      opts = MCPPlug.init(server: Fixtures.Server)

      conn =
        conn(:options, "/", "")
        |> put_req_header("origin", "http://localhost")
        |> MCPPlug.call(opts)

      assert conn.status == 405
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "no Origin means no CORS headers — a non-browser client needs none" do
      conn = post(@opts, [{"authorization", "Bearer valid-token"}])
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end
end
