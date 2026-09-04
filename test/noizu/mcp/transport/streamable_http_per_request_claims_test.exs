defmodule Noizu.MCP.Transport.StreamableHTTPPerRequestClaimsTest do
  @moduledoc """
  PRD-2 per-request claims over the streamable HTTP plug: verified claims are
  forwarded on EVERY deliver (not frozen at initialize), the initialize-time
  fold stays for back-compat, and a ready `:mcp_principal` assign wins.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Transport.StreamableHTTP

  @plug_opts StreamableHTTP.Plug.init(
               server: Fixtures.ACL.AuthedServer,
               auth: [verifier: Fixtures.ACL.SubjectVerifier],
               sse_commit_after: 5_000
             )

  setup_all do
    Noizu.MCP.Test.ensure_server_started(Fixtures.ACL.AuthedServer)
  end

  defp post_json(body, headers, assigns \\ []) do
    conn =
      conn(:post, "/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      Enum.reduce(assigns, conn, fn {key, value}, conn -> assign(conn, key, value) end)

    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> StreamableHTTP.Plug.call(@plug_opts)
  end

  defp initialize(token) do
    conn =
      post_json(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "claims_test", "version" => "1.0.0"}
          }
        },
        authorization(token)
      )

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")

    notify_conn =
      post_json(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        authorization(token) ++ [{"mcp-session-id", session_id}]
      )

    assert notify_conn.status == 202
    session_id
  end

  defp authorization(nil), do: []
  defp authorization(token), do: [{"authorization", "Bearer #{token}"}]

  defp auth_echo(session_id, token) do
    conn =
      post_json(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "auth_echo", "arguments" => %{}}
        },
        authorization(token) ++
          [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]
      )

    assert conn.status == 200
    %{"result" => result} = Jason.decode!(conn.resp_body)
    auth_result(result)
  end

  defp auth_result(%{"structuredContent" => auth}), do: auth
  defp auth_result(%{"content" => [%{"text" => "anonymous"}]}), do: "anonymous"

  describe "per-request claims (FR-2.4)" do
    test "a claims change is visible on the NEXT request" do
      session_id = initialize("alice-token")

      assert auth_echo(session_id, "alice-token")["subject"] == "alice"
      assert auth_echo(session_id, "bob-token")["subject"] == "bob"
      assert auth_echo(session_id, "alice-token")["subject"] == "alice"

      # bob's scopes come along per request too.
      assert auth_echo(session_id, "bob-token")["scopes"] == ["mcp:write", "pm:docs"]
    end

    test "initialize-path back-compat: frozen claims answer when per-request claims resolve to nothing" do
      session_id = initialize("alice-token")

      # A verifier-passed token whose claims lack "sub" maps to a nil
      # principal ⇒ build_ctx falls through to the initialize-time
      # `auth_claims` assign (handlers reading ctx.assigns[:auth_claims]
      # keep working through the third precedence).
      assert auth_echo(session_id, "no-sub-token")["subject"] == "alice"
    end

    test "a verifier-rejected token never reaches the session" do
      conn =
        post_json(
          %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"},
          authorization("bogus-token")
        )

      assert conn.status == 401
    end

    test "claims without a sub are anonymous when no initialize fallback exists" do
      # Sub-less claims at initialize ⇒ no frozen principal; per-request
      # sub-less claims map to nil — anonymous, never a synthetic subject.
      session_id = initialize("no-sub-token")
      assert auth_echo(session_id, "no-sub-token") == "anonymous"
    end
  end

  describe ":mcp_principal assign seam (FR-2.5 §4.5b)" do
    test "a ready principal folded at initialize wins over frozen claims" do
      principal = %Principal{subject: "plug-principal", authenticator: :plug}

      conn =
        post_json(
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "claims_test", "version" => "1.0.0"}
            }
          },
          authorization("alice-token"),
          mcp_principal: principal
        )

      assert conn.status == 200
      [session_id] = get_resp_header(conn, "mcp-session-id")

      post_json(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        authorization("alice-token") ++ [{"mcp-session-id", session_id}]
      )

      # Per-request claims that map to no principal ⇒ no current_auth ⇒ the
      # plugged principal wins over the initialize claims fold.
      assert auth_echo(session_id, "no-sub-token")["subject"] == "plug-principal"

      # Per-request claims outrank the plugged principal (deliver/3 first).
      assert auth_echo(session_id, "bob-token")["subject"] == "bob"
    end
  end
end
