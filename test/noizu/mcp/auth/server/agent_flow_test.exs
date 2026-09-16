defmodule Noizu.MCP.Auth.Server.AgentFlowTest do
  @moduledoc """
  The anonymous-agent flow end to end, at the service layer: open a session,
  register, sign an assertion, get a token, manage keys, get approved.

  The assertions that matter most here are the ones about *refusal*, because the
  whole scheme is an unauthenticated write endpoint followed by a signature check:

    * a replayed assertion is refused even though its signature is perfectly valid
    * a spent session is refused even though the assertion is fresh
    * a key belonging to account A cannot authenticate as account B
    * key management is refused to a token that did not come from a signature
    * suspending an account invalidates tokens already in flight
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Agent
  alias Noizu.MCP.Auth.Server.Agent.Assertion
  alias Noizu.MCP.Auth.Server.Agent.Key
  alias Noizu.MCP.Auth.Server.Store

  @issuer "https://agents.example.test"

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

    %{config: config, store: store}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private, fingerprint: Key.thumbprint(public)}
  end

  defp open_session(config, kp, params \\ %{}) do
    {:ok, body} =
      Agent.start_session(
        config,
        Map.merge(%{"public_key" => Key.encode(kp.public)}, params),
        remote_ip: {127, 0, 0, 1}
      )

    body
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

  defp onboard(config, handle) do
    kp = keypair()
    session = open_session(config, kp)
    {:ok, %{"account" => account}} =
      Agent.register(config, session["session_token"], %{"handle" => handle})

    %{kp: kp, account: account, session: session}
  end

  defp token_for(config, %{kp: kp, account: account}) do
    session = open_session(config, kp)
    assertion = assertion_for(kp, session, account["account_id"], account["handle"])
    {:ok, body} = Agent.authenticate(config, assertion)
    body
  end

  defp claims_of(config, token) do
    {:ok, claims} = Agent.verify_token(config, token)
    claims
  end

  # ── the happy path ───────────────────────────────────────────────────────

  describe "the flow" do
    test "an unknown agent is told registration is required", %{config: config} do
      session = open_session(config, keypair())

      assert session["registration_required"]
      assert is_nil(session["account"])
      assert is_binary(session["nonce"])
      assert session["token_endpoint"] == @issuer <> "/oauth/token"
    end

    test "a returning agent is told it already has an account", %{config: config} do
      %{kp: kp, account: account} = onboard(config, "returning-agent")

      session = open_session(config, kp)

      refute session["registration_required"]
      assert session["account"]["handle"] == account["handle"]
    end

    test "registration creates a pending account bound to the session key",
         %{config: config} do
      kp = keypair()
      session = open_session(config, kp)

      {:ok, body} = Agent.register(config, session["session_token"], %{"handle" => "new-agent"})

      assert body["account"]["status"] == "pending"
      assert body["account"]["handle"] == "new-agent"
      assert body["key"]["fingerprint"] == kp.fingerprint
    end

    test "a signed assertion yields a token carrying amr sig and pending status",
         %{config: config} do
      agent = onboard(config, "signing-agent")
      body = token_for(config, agent)

      assert body["status"] == "pending"
      claims = claims_of(config, body["access_token"])
      assert claims["amr"] == ["sig"]
      assert claims["act"] == agent.account["account_id"]
      assert claims["hdl"] == "signing-agent"
      assert claims["kid"] == agent.kp.fingerprint
      assert claims["st"] == "pending"
    end

    test "approval widens the scope on the next token", %{config: config} do
      agent = onboard(config, "approved-agent")

      pending = token_for(config, agent)
      refute pending["scope"] =~ "mcp"

      {:ok, _} =
        Agent.set_status(config, agent.account["account_id"], :approved, actor: "admin@example")

      approved = token_for(config, agent)
      assert approved["scope"] =~ "mcp"
      assert approved["status"] == "approved"
    end
  end

  # ── refusals: this is the security surface ───────────────────────────────

  describe "replay" do
    test "the same assertion cannot be used twice", %{config: config} do
      agent = onboard(config, "replay-agent")
      session = open_session(config, agent.kp)

      assertion =
        assertion_for(agent.kp, session, agent.account["account_id"], agent.account["handle"])

      assert {:ok, _} = Agent.authenticate(config, assertion)
      assert {:error, code} = Agent.authenticate(config, assertion)
      assert code in [:assertion_replayed, :session_replayed]
    end

    test "a fresh assertion against a spent session is refused", %{config: config} do
      agent = onboard(config, "spent-session-agent")
      session = open_session(config, agent.kp)

      first =
        assertion_for(agent.kp, session, agent.account["account_id"], agent.account["handle"])

      assert {:ok, _} = Agent.authenticate(config, first)

      # New jti, new signature, same session — the nonce is what is spent.
      second =
        assertion_for(agent.kp, session, agent.account["account_id"], agent.account["handle"])

      assert {:error, :session_replayed} = Agent.authenticate(config, second)
    end

    test "an assertion carrying another session's nonce is refused", %{config: config} do
      agent = onboard(config, "nonce-swap-agent")
      mine = open_session(config, agent.kp)
      theirs = open_session(config, agent.kp)

      forged =
        assertion_for(agent.kp, mine, agent.account["account_id"], agent.account["handle"], %{
          "nonce" => theirs["nonce"]
        })

      assert {:error, _} = Agent.authenticate(config, forged)
    end
  end

  describe "identity" do
    test "one agent cannot authenticate as another", %{config: config} do
      a = onboard(config, "agent-alpha")
      b = onboard(config, "agent-beta")

      session = open_session(config, a.kp)

      # Alpha's key, signing a claim to be Beta.
      forged = assertion_for(a.kp, session, b.account["account_id"], b.account["handle"])

      assert {:error, :invalid_assertion} = Agent.authenticate(config, forged)
    end

    test "an unregistered key is refused", %{config: config} do
      agent = onboard(config, "known-agent")
      stranger = keypair()
      session = open_session(config, stranger)

      assertion =
        assertion_for(stranger, session, agent.account["account_id"], agent.account["handle"])

      assert {:error, :unknown_key} = Agent.authenticate(config, assertion)
    end

    test "a handle cannot be registered twice", %{config: config} do
      onboard(config, "taken-handle")

      kp = keypair()
      session = open_session(config, kp)

      assert {:error, :handle_taken} =
               Agent.register(config, session["session_token"], %{"handle" => "taken-handle"})
    end

    test "a key already bound to an account cannot register a second one",
         %{config: config} do
      agent = onboard(config, "one-account-agent")
      session = open_session(config, agent.kp)

      assert {:error, :already_registered} =
               Agent.register(config, session["session_token"], %{"handle" => "second-identity"})
    end

    test "a reserved handle is refused", %{config: config} do
      kp = keypair()
      session = open_session(config, kp)

      assert {:error, :handle_invalid} =
               Agent.register(config, session["session_token"], %{"handle" => "adm1n"})
    end
  end

  describe "key management" do
    test "requires a token obtained by signature", %{config: config} do
      agent = onboard(config, "keys-agent")
      body = token_for(config, agent)
      claims = claims_of(config, body["access_token"])

      # Same account, same epoch — only `amr` differs.
      password_claims = Map.put(claims, "amr", ["pwd"])

      assert {:error, :signature_required} = Agent.add_key(config, password_claims, %{})
      assert {:error, :signature_required} = Agent.revoke_key(config, password_claims, "x")
    end

    test "adding a key needs both proofs, and the new key then authenticates",
         %{config: config} do
      agent = onboard(config, "rotating-agent")
      claims = claims_of(config, token_for(config, agent)["access_token"])

      fresh = keypair()

      params = %{
        "public_key" => Key.encode(fresh.public),
        "label" => "second key",
        "proof_existing" => proof(agent.kp, agent.account, fresh.fingerprint),
        "proof_new" => proof(fresh, agent.account, fresh.fingerprint)
      }

      assert {:ok, added} = Agent.add_key(config, claims, params)
      assert added["fingerprint"] == fresh.fingerprint
      assert added["added_via"] == agent.kp.fingerprint

      # The new key really works.
      session = open_session(config, fresh)

      assertion =
        assertion_for(fresh, session, agent.account["account_id"], agent.account["handle"])

      assert {:ok, _} = Agent.authenticate(config, assertion)
    end

    test "a missing or wrong proof_existing is refused", %{config: config} do
      agent = onboard(config, "unproven-agent")
      claims = claims_of(config, token_for(config, agent)["access_token"])
      fresh = keypair()
      stranger = keypair()

      base = %{
        "public_key" => Key.encode(fresh.public),
        "proof_new" => proof(fresh, agent.account, fresh.fingerprint)
      }

      assert {:error, :invalid_assertion} = Agent.add_key(config, claims, base)

      assert {:error, :unknown_key} =
               Agent.add_key(
                 config,
                 claims,
                 Map.put(base, "proof_existing", proof(stranger, agent.account, fresh.fingerprint))
               )
    end

    test "a proof bound to a different key is refused", %{config: config} do
      agent = onboard(config, "mismatched-proof-agent")
      claims = claims_of(config, token_for(config, agent)["access_token"])
      fresh = keypair()
      other = keypair()

      params = %{
        "public_key" => Key.encode(fresh.public),
        # Proofs are for `other`, the key being added is `fresh`.
        "proof_existing" => proof(agent.kp, agent.account, other.fingerprint),
        "proof_new" => proof(fresh, agent.account, other.fingerprint)
      }

      assert {:error, :invalid_assertion} = Agent.add_key(config, claims, params)
    end

    test "the last active key cannot be revoked", %{config: config} do
      agent = onboard(config, "sole-key-agent")
      claims = claims_of(config, token_for(config, agent)["access_token"])

      assert {:error, :last_key} = Agent.revoke_key(config, claims, agent.kp.fingerprint)
    end

    test "a revoked key stops authenticating but is still listed", %{config: config} do
      agent = onboard(config, "revoking-agent")
      claims = claims_of(config, token_for(config, agent)["access_token"])
      fresh = keypair()

      {:ok, _} =
        Agent.add_key(config, claims, %{
          "public_key" => Key.encode(fresh.public),
          "proof_existing" => proof(agent.kp, agent.account, fresh.fingerprint),
          "proof_new" => proof(fresh, agent.account, fresh.fingerprint)
        })

      assert {:ok, _} = Agent.revoke_key(config, claims, agent.kp.fingerprint)

      session = open_session(config, agent.kp)

      assertion =
        assertion_for(agent.kp, session, agent.account["account_id"], agent.account["handle"])

      assert {:error, :key_revoked} = Agent.authenticate(config, assertion)

      {:ok, %{"keys" => keys}} = Agent.list_keys(config, claims)
      assert Enum.any?(keys, &(&1["fingerprint"] == agent.kp.fingerprint and &1["revoked_at"]))
    end
  end

  describe "moderation" do
    test "suspension invalidates a token already in flight", %{config: config} do
      agent = onboard(config, "suspended-agent")
      token = token_for(config, agent)["access_token"]

      assert {:ok, _} = Agent.verify_token(config, token)

      {:ok, _} =
        Agent.set_status(config, agent.account["account_id"], :suspended,
          actor: "admin@example",
          reason: "spam"
        )

      # The signature and expiry are still fine; the epoch is not.
      assert {:error, :invalid_session} = Agent.verify_token(config, token)
    end

    test "a suspended or rejected account cannot obtain a new token", %{config: config} do
      agent = onboard(config, "rejected-agent")

      {:ok, _} = Agent.set_status(config, agent.account["account_id"], :rejected, actor: "admin")

      session = open_session(config, agent.kp)

      assertion =
        assertion_for(agent.kp, session, agent.account["account_id"], agent.account["handle"])

      assert {:error, :account_rejected} = Agent.authenticate(config, assertion)
    end
  end

  describe "configuration" do
    test "the feature is off unless enabled", %{store: store} do
      config =
        Server.config(
          issuer: @issuer,
          store: {Store.ETS, name: store},
          signing: {:hs256, "test-secret-that-is-long-enough-to-be-a-key"},
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []}
        )

      refute Agent.supported?(config)
      assert {:error, :agent_auth_disabled} = Agent.start_session(config, %{})
    end

    test "enabling it against a store that cannot serve it fails at boot" do
      assert_raise ArgumentError, ~r/does not implement/, fn ->
        Server.config(
          issuer: @issuer,
          store: {__MODULE__.HalfStore, []},
          signing: {:hs256, "test-secret-that-is-long-enough-to-be-a-key"},
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []},
          agent_auth: [enabled: true]
        )
      end
    end
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

  defmodule HalfStore do
    @moduledoc "A store with none of the agent callbacks, to prove boot refuses it."
  end
end
