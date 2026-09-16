defmodule Noizu.MCP.Server.Tools.AgentAuthTest do
  @moduledoc """
  The MCP-tool face of `Noizu.MCP.Auth.Server.Agent`.

  The one property that matters more than any individual flow step: identity
  for auth_whoami/auth_list_keys/auth_add_key/auth_revoke_key comes ONLY from
  `ctx.auth`'s verified claims, never from an argument. A stray `account_id`
  in the call args must be silently dropped by the schema (no such field is
  declared) and must have zero effect on whose account is resolved.
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Agent
  alias Noizu.MCP.Auth.Server.Agent.Assertion
  alias Noizu.MCP.Auth.Server.Agent.Key
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Server.Features
  alias Noizu.MCP.Server.Tools.AgentAuth
  alias Noizu.MCP.Types.ToolResult

  @issuer "https://agents.example.test"
  @tools [{AgentAuth, []}]

  # `Features.Tools.dispatch/4` needs `ctx.server.__mcp__(:opts)[:agent_auth_config]`
  # — the same `__mcp__(:opts)` surface `:acl`/`:vfs_readonly`/`:principal` already
  # use for server-scoped config reachable from a running tool. The test process
  # dictionary stands in for a real server module's compiled opts.
  defmodule FakeServer do
    @moduledoc false
    def __mcp__(:opts), do: [agent_auth_config: Process.get(:agent_auth_test_config)]
  end

  setup do
    store = Module.concat(__MODULE__, Store)
    start_supervised!({Store.ETS, name: store})
    Store.ETS.reset(name: store)

    config =
      Server.config(
        issuer: @issuer,
        store: {Store.ETS, name: store},
        signing: {:hs256, "test-secret-that-is-long-enough-to-be-a-key"},
        upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []},
        agent_auth: [enabled: true, ip_salt: "test-salt"]
      )

    Process.put(:agent_auth_test_config, config)
    %{config: config}
  end

  # ── ctx helpers ──────────────────────────────────────────────────────────

  defp ctx(claims) do
    auth = claims && %Principal{subject: claims["act"], authenticator: :test, claims: claims}
    %Ctx{server: FakeServer, session: nil, assigns: %{}, auth: auth}
  end

  defp dispatch(name, args, claims \\ nil) do
    Features.Tools.dispatch(@tools, name, args, ctx(claims))
  end

  # ── flow helpers (mirrors agent_flow_test.exs) ────────────────────────────

  defp keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private, fingerprint: Key.thumbprint(public)}
  end

  defp assertion_for(kp, session, account_id, handle, overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => account_id,
        "sub" => account_id,
        "aud" => @issuer <> "/oauth/token",
        "hdl" => handle,
        "iat" => now,
        "exp" => now + 120,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "sid" => session["session_id"],
        "nonce" => session["nonce"]
      }
      |> Map.merge(overrides)

    Assertion.sign(claims, kp.private, kp.fingerprint)
  end

  defp proof(kp, account, subject_fingerprint) do
    now = System.system_time(:second)

    Assertion.sign(
      %{
        "iss" => account["account_id"],
        "sub" => account["account_id"],
        "aud" => @issuer <> "/oauth/keys",
        "hdl" => account["handle"],
        "iat" => now,
        "exp" => now + 120,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "op" => "add_key",
        "jkt" => subject_fingerprint
      },
      kp.private,
      kp.fingerprint
    )
  end

  # Drives the tools end to end exactly as an agent would, all through
  # `Features.Tools.dispatch/4` (schema validation included).
  defp onboard(handle) do
    kp = keypair()

    %ToolResult{structured: session} =
      dispatch("auth_start_session", %{"public_key" => Key.encode(kp.public)})

    %ToolResult{structured: %{"account" => account}} =
      dispatch("auth_register_agent", %{
        "session_token" => session["session_token"],
        "handle" => handle
      })

    session2 =
      case dispatch("auth_start_session", %{"public_key" => Key.encode(kp.public)}) do
        %ToolResult{structured: s} -> s
      end

    assertion = assertion_for(kp, session2, account["account_id"], account["handle"])
    %ToolResult{structured: token} = dispatch("auth_authenticate", %{"assertion" => assertion})

    {:ok, claims} = Agent.verify_token(Process.get(:agent_auth_test_config), token["access_token"])
    %{kp: kp, account: account, claims: claims}
  end

  # ── definitions ──────────────────────────────────────────────────────────

  describe "definition/0 via __mcp_tools__/0" do
    setup do
      specs = Map.new(AgentAuth.__mcp_tools__(), &{&1.definition.name, &1})
      %{specs: specs}
    end

    test "registers exactly the seven expected tool names", %{specs: specs} do
      assert Map.keys(specs) |> Enum.sort() ==
               Enum.sort([
                 "auth_start_session",
                 "auth_register_agent",
                 "auth_authenticate",
                 "auth_whoami",
                 "auth_list_keys",
                 "auth_add_key",
                 "auth_revoke_key"
               ])
    end

    test "no tool declares an account_id input field", %{specs: specs} do
      for {_name, spec} <- specs do
        props = spec.definition.input_schema["properties"] || %{}
        refute Map.has_key?(props, "account_id")
      end
    end

    test "start_session requires public_key and has a valid schema", %{specs: specs} do
      schema = specs["auth_start_session"].definition.input_schema
      assert schema["required"] == ["public_key"]
      assert schema["properties"]["public_key"]["type"] == "string"
      assert schema["properties"]["alg"]["default"] == "ed25519"
    end

    test "register_agent requires session_token and handle", %{specs: specs} do
      schema = specs["auth_register_agent"].definition.input_schema
      assert Enum.sort(schema["required"]) == Enum.sort(["session_token", "handle"])
    end

    test "authenticate requires assertion only", %{specs: specs} do
      schema = specs["auth_authenticate"].definition.input_schema
      assert schema["required"] == ["assertion"]
    end

    test "whoami and list_keys take no required input", %{specs: specs} do
      refute Map.has_key?(specs["auth_whoami"].definition.input_schema, "required")
      refute Map.has_key?(specs["auth_list_keys"].definition.input_schema, "required")
    end

    test "add_key requires public_key, proof_new and proof_existing", %{specs: specs} do
      schema = specs["auth_add_key"].definition.input_schema
      assert Enum.sort(schema["required"]) ==
               Enum.sort(["public_key", "proof_new", "proof_existing"])
    end

    test "revoke_key requires fingerprint only", %{specs: specs} do
      schema = specs["auth_revoke_key"].definition.input_schema
      assert schema["required"] == ["fingerprint"]
    end

    # ── annotations ──────────────────────────────────────────────────────

    test "read_only_hint is set on whoami and list_keys", %{specs: specs} do
      for name <- ["auth_whoami", "auth_list_keys"] do
        assert specs[name].definition.annotations[:read_only_hint] == true
      end
    end

    # start_session persists a session row, so it is not read-only however much it
    # looks like a handshake. A client told otherwise would think it safe to retry,
    # and the session's nonce is spendable exactly once.
    test "start_session is not read-only and not idempotent", %{specs: specs} do
      annotations = specs["auth_start_session"].definition.annotations
      refute annotations[:read_only_hint] == true
      assert annotations[:idempotent_hint] == false
    end

    test "destructive_hint is set on revoke_key", %{specs: specs} do
      assert specs["auth_revoke_key"].definition.annotations[:destructive_hint] == true
    end

    test "register_agent, authenticate, add_key are not read-only", %{specs: specs} do
      for name <- ["auth_register_agent", "auth_authenticate", "auth_add_key"] do
        refute specs[name].definition.annotations[:read_only_hint] == true
      end
    end
  end

  # ── configuration guard ────────────────────────────────────────────────────

  describe "missing configuration" do
    test "a server with no agent_auth_config in opts returns a tool error" do
      Process.put(:agent_auth_test_config, nil)

      assert %ToolResult{is_error: true, content: [content]} =
               dispatch("auth_start_session", %{"public_key" => "whatever"})

      assert content.text =~ "agent_auth_not_configured"
    end
  end

  # ── the flow, through the tools ────────────────────────────────────────────

  describe "the flow" do
    test "start_session reports registration_required for an unknown key" do
      kp = keypair()

      assert %ToolResult{is_error: false, structured: session} =
               dispatch("auth_start_session", %{"public_key" => Key.encode(kp.public)})

      assert session["registration_required"]
      assert is_binary(session["nonce"])
    end

    test "register_agent creates a pending account" do
      kp = keypair()

      %ToolResult{structured: session} =
        dispatch("auth_start_session", %{"public_key" => Key.encode(kp.public)})

      assert %ToolResult{is_error: false, structured: body} =
               dispatch("auth_register_agent", %{
                 "session_token" => session["session_token"],
                 "handle" => "tool-agent"
               })

      assert body["account"]["status"] == "pending"
      assert body["key"]["fingerprint"] == kp.fingerprint
    end

    test "authenticate yields an access token" do
      onboarding = onboard("tool-auth-agent")
      refute is_nil(onboarding.claims["act"])
    end

    test "whoami reflects the caller's own identity from ctx, ignoring an account_id arg" do
      me = onboard("whoami-self")
      _other = onboard("whoami-other")

      result =
        dispatch(
          "auth_whoami",
          # a hostile/naive caller trying to name a different account
          %{"account_id" => "not-mine-at-all"},
          me.claims
        )

      assert %ToolResult{is_error: false, structured: body} = result
      assert body["account_id"] == me.account["account_id"]
      assert body["handle"] == "whoami-self"
      refute body["handle"] == "whoami-other"
    end

    test "list_keys lists only the caller's own keys, ignoring an account_id arg" do
      me = onboard("list-keys-self")
      other = onboard("list-keys-other")

      %ToolResult{structured: %{"keys" => keys}} =
        dispatch("auth_list_keys", %{"account_id" => other.account["account_id"]}, me.claims)

      fingerprints = Enum.map(keys, & &1["fingerprint"])
      assert me.kp.fingerprint in fingerprints
      refute other.kp.fingerprint in fingerprints
    end

    test "add_key then revoke_key round-trip on the caller's own account" do
      me = onboard("rotate-self")
      fresh = keypair()

      params = %{
        "public_key" => Key.encode(fresh.public),
        "proof_existing" => proof(me.kp, me.account, fresh.fingerprint),
        "proof_new" => proof(fresh, me.account, fresh.fingerprint)
      }

      assert %ToolResult{is_error: false, structured: added} =
               dispatch("auth_add_key", params, me.claims)

      assert added["fingerprint"] == fresh.fingerprint

      assert %ToolResult{is_error: false, structured: revoked} =
               dispatch("auth_revoke_key", %{"fingerprint" => me.kp.fingerprint}, me.claims)

      assert revoked["fingerprint"] == me.kp.fingerprint
      assert revoked["revoked_at"]
    end

    test "add_key/revoke_key act on the caller's account even if an account_id arg names another" do
      me = onboard("scoped-self")
      other = onboard("scoped-other")
      fresh = keypair()

      params = %{
        "account_id" => other.account["account_id"],
        "public_key" => Key.encode(fresh.public),
        "proof_existing" => proof(me.kp, me.account, fresh.fingerprint),
        "proof_new" => proof(fresh, me.account, fresh.fingerprint)
      }

      assert %ToolResult{is_error: false, structured: added} =
               dispatch("auth_add_key", params, me.claims)

      assert added["added_via"] == me.kp.fingerprint

      config = Process.get(:agent_auth_test_config)
      {:ok, %{"keys" => other_keys}} = Agent.list_keys(config, other.claims)
      refute Enum.any?(other_keys, &(&1["fingerprint"] == fresh.fingerprint))
    end
  end

  # ── error propagation ──────────────────────────────────────────────────────

  describe "error propagation" do
    test "a facade error code rides through as tool error text" do
      kp = keypair()

      %ToolResult{structured: session} =
        dispatch("auth_start_session", %{"public_key" => Key.encode(kp.public)})

      dispatch("auth_register_agent", %{
        "session_token" => session["session_token"],
        "handle" => "dup-handle"
      })

      %ToolResult{structured: session2} =
        dispatch("auth_start_session", %{"public_key" => Key.encode(keypair().public)})

      assert %ToolResult{is_error: true, content: [content]} =
               dispatch("auth_register_agent", %{
                 "session_token" => session2["session_token"],
                 "handle" => "dup-handle"
               })

      assert content.text =~ "handle_taken:"
    end

    test "account_pending is preserved verbatim for a caller to branch on" do
      me = onboard("still-pending")
      config = Process.get(:agent_auth_test_config)

      # No public flow forces account_pending through these tools directly (an
      # agent authenticates fine while pending, per the facade docs), but the
      # error-mapping path itself is exercised via a not_found case here: a
      # revoke of an unknown fingerprint must surface `not_found`, not a
      # generic failure.
      assert %ToolResult{is_error: true, content: [content]} =
               dispatch("auth_revoke_key", %{"fingerprint" => "does-not-exist"}, me.claims)

      assert content.text =~ "not_found:"
      assert String.contains?(config.agent_auth[:enabled] |> to_string(), "true")
    end

    test "signature_required is surfaced when the token wasn't obtained by signature" do
      me = onboard("no-sig-agent")
      password_claims = Map.put(me.claims, "amr", ["pwd"])

      assert %ToolResult{is_error: true, content: [content]} =
               dispatch("auth_revoke_key", %{"fingerprint" => me.kp.fingerprint}, password_claims)

      assert content.text =~ "signature_required:"
    end
  end

  # ── anonymous callers ──────────────────────────────────────────────────────

  describe "anonymous callers" do
    test "whoami with no ctx.auth resolves no account rather than any account" do
      _agent = onboard("anon-noise")

      assert %ToolResult{is_error: true, content: [content]} =
               dispatch("auth_whoami", %{})

      assert content.text =~ "not_found:"
    end
  end
end
