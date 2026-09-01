defmodule Noizu.MCP.Server.SessionAuthTest do
  use ExUnit.Case, async: true

  import Noizu.MCP.Test

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.JsonRpc
  alias Noizu.MCP.JsonRpc.Request
  alias Noizu.MCP.Server.{Session, Supervisor}

  @await timeout: 2_000

  defp deliver_claims(client, method, params, claims) do
    :counters.add(client.counter, 1, 1)
    id = :counters.get(client.counter, 1)

    binary =
      IO.iodata_to_binary(JsonRpc.encode!(%Request{id: id, method: method, params: params}))

    Session.deliver(client.session, binary, claims)
    id
  end

  defp auth_echo(client, claims) do
    id =
      deliver_claims(client, "tools/call", %{"name" => "auth_echo", "arguments" => %{}}, claims)

    assert {:ok, result} = await(client, id, @await)
    auth_result(result)
  end

  defp auth_echo_no_claims(client) do
    id = send_request(client, "tools/call", %{"name" => "auth_echo", "arguments" => %{}})
    assert {:ok, result} = await(client, id, @await)
    auth_result(result)
  end

  defp auth_result(%{"structuredContent" => auth}), do: auth
  defp auth_result(%{"content" => [%{"text" => "anonymous"}]}), do: "anonymous"

  defp current_auth(client), do: :sys.get_state(client.session).current_auth

  # ── arity-2 path (stdio / sse / vfs_ws semantics) ───────────────────────────

  describe "deliver/2 leaves the session anonymous (FR-2.3)" do
    test "a plain deliver/2 session never sets auth" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      assert auth_echo_no_claims(client) == "anonymous"
      assert current_auth(client) == nil
    end
  end

  # ── deliver/3: per-request claims ───────────────────────────────────────────

  describe "deliver/3 built-in claims mapping (FR-2.5)" do
    test "claims resolve to a principal for exactly that message" do
      client = connect(Fixtures.ACL.UnconfiguredServer)

      auth =
        auth_echo(client, %{"sub" => "alice", "scope" => "mcp:read pm:docs", "tid" => "tok-1"})

      assert auth["subject"] == "alice"
      assert auth["authenticator"] == "claims"
      assert auth["token_id"] == nil
      assert auth["scopes"] == ["mcp:read", "pm:docs"]
    end

    test "claims lacking sub are anonymous — never a synthetic subject" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      assert auth_echo(client, %{"scope" => "mcp"}) == "anonymous"
    end

    test "nil claims are anonymous" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      assert auth_echo(client, nil) == "anonymous"
    end

    test "current_auth is cleared once the message completes (FR-2.2)" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      assert auth_echo(client, %{"sub" => "alice"})["subject"] == "alice"
      assert current_auth(client) == nil

      # The next claim-less message does not inherit it.
      assert auth_echo_no_claims(client) == "anonymous"
    end

    test "server-initiated notifications never carry the principal (AC-2.5)" do
      server = Fixtures.ACL.UnconfiguredServer
      client = connect(server)

      assert auth_echo(client, %{"sub" => "alice"})["subject"] == "alice"

      :ok = server.notify_changed(:tools)
      assert_notification(client, "notifications/tools/list_changed", nil, @await)
      assert current_auth(client) == nil
    end
  end

  describe "principal: MFA mapping (FR-2.5, AC-2.6)" do
    test "the mapper receives the raw claims plus its opts; result lands in ctx.auth" do
      client = connect(Fixtures.ACL.MappedServer)

      auth = auth_echo(client, %{"sub" => "carol", "tid" => "tok-9"})

      assert auth["subject"] == "carol"
      assert auth["authenticator"] == "test"
      assert auth["token_id"] == "tok-9"
      assert auth["metadata"] == %{"opts" => %{"realm" => "fixture"}}
    end

    test "{:error, _} from the mapper fails open to anonymous" do
      client = connect(Fixtures.ACL.FailingMapperServer)
      assert auth_echo(client, %{"sub" => "carol"}) == "anonymous"
    end

    test "a mapper raise fails open to anonymous" do
      client = connect(Fixtures.ACL.RaisingMapperServer)
      assert auth_echo(client, %{"sub" => "carol"}) == "anonymous"
    end

    test "a mapper returning garbage fails open to anonymous" do
      client = connect(Fixtures.ACL.GarbageMapperServer)
      assert auth_echo(client, %{"sub" => "carol"}) == "anonymous"
    end

    test "nil claims skip the mapper entirely" do
      client = connect(Fixtures.ACL.MappedServer)
      assert auth_echo(client, nil) == "anonymous"
    end
  end

  describe "build_ctx auth precedence (FR-2.2)" do
    defp plugged_principal,
      do: %Principal{
        subject: "plugged",
        authenticator: :plug,
        granted_scopes: MapSet.new(["pm:*"])
      }

    test "current_auth (deliver/3) wins over the plugged principal" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      :ok = Session.put_principal(client.session, plugged_principal())

      assert auth_echo(client, %{"sub" => "via-claims"})["subject"] == "via-claims"
    end

    test "the plugged principal wins over initialize auth_claims" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      :ok = Session.put_assign(client.session, :auth_claims, %{"sub" => "from-claims"})
      :ok = Session.put_principal(client.session, plugged_principal())

      assert auth_echo_no_claims(client)["subject"] == "plugged"
    end

    test "initialize auth_claims still flow per request (back-compat path)" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      :ok = Session.put_assign(client.session, :auth_claims, %{"sub" => "from-claims"})

      assert auth_echo_no_claims(client)["subject"] == "from-claims"
    end

    test "nil principal clears the plugged principal" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      :ok = Session.put_assign(client.session, :auth_claims, %{"sub" => "from-claims"})
      :ok = Session.put_principal(client.session, plugged_principal())
      :ok = Session.put_principal(client.session, nil)

      assert auth_echo_no_claims(client)["subject"] == "from-claims"
    end

    test "nothing set ⇒ anonymous" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      assert auth_echo_no_claims(client) == "anonymous"
    end

    test "put_principal lands on the same assigns key the plug folds in" do
      client = connect(Fixtures.ACL.UnconfiguredServer)
      :ok = Session.put_principal(client.session, plugged_principal())
      state = :sys.get_state(client.session)
      assert state.assigns[:mcp_principal].subject == "plugged"
    end
  end

  describe "raw session wiring" do
    test "deliver/3 on a raw session resolves claims (Supervisor path)" do
      client = connect(Fixtures.ACL.MappedServer)

      # Hand-deliver a second request on the same session with different claims.
      auth =
        auth_echo(client, %{"sub" => "dave", "tid" => "tok-2"})

      assert auth["subject"] == "dave"

      # The session is reusable and anonymous again for plain traffic.
      assert auth_echo_no_claims(client) == "anonymous"
      assert Supervisor.sessions(Fixtures.ACL.MappedServer) != []
    end
  end
end
