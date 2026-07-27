defmodule Noizu.MCP.Auth.ProtectedResourceMetadataPlugTest do
  @moduledoc """
  RFC 9728 discovery. Two failures here are silent in production and fatal to
  claude.ai: a missing `Access-Control-Allow-Origin` (browser discovery fails
  with no error the server can see) and a document that answers the wrong
  suffix with some other mount's `resource`.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn

  alias Noizu.MCP.Auth.ProtectedResourceMetadataPlug, as: PRM

  @single PRM.init(
            resource: "https://api.example.com/mcp",
            authorization_servers: ["https://auth.example.com"],
            scopes_supported: ["mcp"],
            bearer_methods_supported: ["header"],
            resource_name: "Example MCP"
          )

  @multi PRM.init(
           authorization_servers: ["https://app.example.com"],
           scopes_supported: ["mcp"],
           bearer_methods_supported: ["header"],
           default_resource: "/mcp",
           resources: %{
             "/mcp" => [resource: "https://app.example.com/mcp", resource_name: "Root"],
             "/mcp/learning" => [resource: "https://app.example.com/mcp/learning"],
             "/mcp/workspace" => [
               resource: "https://app.example.com/mcp/workspace",
               scopes_supported: ["mcp", "mcp:admin"]
             ]
           }
         )

  defp get(opts, path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path, ""), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> PRM.call(opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "single resource" do
    test "serves the RFC 9728 document" do
      conn = get(@single, "/")
      assert conn.status == 200

      assert %{
               "resource" => "https://api.example.com/mcp",
               "authorization_servers" => ["https://auth.example.com"],
               "scopes_supported" => ["mcp"],
               "bearer_methods_supported" => ["header"],
               "resource_name" => "Example MCP"
             } = body(conn)
    end

    test "answers a path-inserted suffix too — the host has only one mount" do
      assert body(get(@single, "/mcp"))["resource"] == "https://api.example.com/mcp"
    end

    test "extra: merges in host-specific fields" do
      opts =
        PRM.init(
          resource: "https://x/mcp",
          authorization_servers: ["https://x"],
          extra: %{"mcp_versions_supported" => ["2025-11-25"]}
        )

      assert body(get(opts, "/"))["mcp_versions_supported"] == ["2025-11-25"]
    end
  end

  describe "multiple resources behind one forward" do
    test "each suffix answers with its own resource" do
      assert body(get(@multi, "/mcp"))["resource"] == "https://app.example.com/mcp"

      assert body(get(@multi, "/mcp/learning"))["resource"] ==
               "https://app.example.com/mcp/learning"

      assert body(get(@multi, "/mcp/workspace"))["resource"] ==
               "https://app.example.com/mcp/workspace"
    end

    test "the bare path answers with default_resource" do
      assert body(get(@multi, "/"))["resource"] == "https://app.example.com/mcp"
    end

    test "top-level options are inherited and per-resource options win" do
      root = body(get(@multi, "/mcp"))
      workspace = body(get(@multi, "/mcp/workspace"))

      assert root["authorization_servers"] == ["https://app.example.com"]
      assert root["scopes_supported"] == ["mcp"]
      assert root["resource_name"] == "Root"
      assert workspace["scopes_supported"] == ["mcp", "mcp:admin"]
      refute Map.has_key?(workspace, "resource_name")
    end

    test "an unknown suffix is 404 — never another mount's document" do
      conn = get(@multi, "/mcp/nope")
      assert conn.status == 404
      assert body(conn) == %{"error" => "not_found"}

      assert get(@multi, "/mcp/learning/extra").status == 404
      assert get(@multi, "/admin").status == 404
    end

    test "a suffix key may be written with or without a leading slash" do
      opts =
        PRM.init(
          authorization_servers: ["https://x"],
          resources: %{"mcp/learning" => [resource: "https://x/mcp/learning"]}
        )

      assert body(get(opts, "/mcp/learning"))["resource"] == "https://x/mcp/learning"
    end

    test "with no default_resource the bare path is 404" do
      opts =
        PRM.init(
          authorization_servers: ["https://x"],
          resources: %{"/mcp" => [resource: "https://x/mcp"]}
        )

      assert get(opts, "/").status == 404
      assert get(opts, "/mcp").status == 200
    end

    test "resources may be given as a keyword list of maps" do
      opts =
        PRM.init(
          authorization_servers: ["https://x"],
          resources: %{"/mcp" => %{resource: "https://x/mcp"}}
        )

      assert body(get(opts, "/mcp"))["resource"] == "https://x/mcp"
    end
  end

  describe "CORS" do
    test "GET carries Access-Control-Allow-Origin — browser discovery needs it" do
      conn = get(@multi, "/mcp", [{"origin", "https://claude.ai"}])
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "a 404 is also CORS-answered, so the client sees the 404 and not an opaque failure" do
      conn = get(@multi, "/mcp/nope", [{"origin", "https://claude.ai"}])
      assert conn.status == 404
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "OPTIONS is 204 with the preflight headers" do
      conn = conn(:options, "/mcp", "") |> PRM.call(@multi)

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, OPTIONS"]
      assert [headers] = get_resp_header(conn, "access-control-allow-headers")
      assert headers =~ "authorization"
      assert get_resp_header(conn, "access-control-max-age") == ["600"]
    end

    test "allow_origin: nil omits the header" do
      opts =
        PRM.init(
          resource: "https://x/mcp",
          authorization_servers: ["https://x"],
          allow_origin: nil
        )

      assert get_resp_header(get(opts, "/"), "access-control-allow-origin") == []
    end

    test "allow_origin may be pinned to one origin" do
      opts =
        PRM.init(
          resource: "https://x/mcp",
          authorization_servers: ["https://x"],
          allow_origin: "https://claude.ai"
        )

      assert get_resp_header(get(opts, "/"), "access-control-allow-origin") ==
               ["https://claude.ai"]
    end
  end

  test "other methods are 405" do
    assert (conn(:post, "/", "") |> PRM.call(@multi)).status == 405
    assert (conn(:delete, "/", "") |> PRM.call(@single)).status == 405
  end
end
