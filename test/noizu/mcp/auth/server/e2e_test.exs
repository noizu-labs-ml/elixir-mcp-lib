defmodule Noizu.MCP.Auth.Server.E2ETest do
  @moduledoc """
  The whole flow over real HTTP, against a Bandit listener carrying everything a
  host mounts: discovery → dynamic registration → authorize → consent → token →
  `tools/call` → refresh, and the CIMD variant of the same.

  Two assertions matter more than the rest, because they are the ones that make
  several MCP mounts on one host safe:

    * a token minted for `/mcp` is **rejected** at `/mcp/learning`, and vice versa
    * a replayed authorization code or refresh token revokes the whole family
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Server.PKCE
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Fixtures

  setup_all do
    store = Module.concat(__MODULE__, Store)
    start_supervised!({Store.ETS, name: store})

    pid =
      start_supervised!(
        {Bandit,
         plug: Fixtures.ASRouter,
         port: 0,
         ip: :loopback,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 10]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"
    Fixtures.AS.setup(base, store)
    Noizu.MCP.Test.ensure_server_started(Fixtures.Server)

    %{base: base, store: store}
  end

  setup %{store: store} do
    Store.ETS.reset(name: store)
    Fixtures.AS.put(:subject, "user-1")
    Fixtures.AS.put(:cimd_document, nil)
    Fixtures.AS.track_upstream(nil)
    :ok
  end

  # ── discovery ────────────────────────────────────────────────────────────

  describe "discovery" do
    test "the metadata document carries the fields Claude gates on", %{base: base} do
      body = get_json(base <> "/.well-known/oauth-authorization-server")

      assert body["issuer"] == base
      assert body["authorization_endpoint"] == base <> "/oauth/authorize"
      assert body["token_endpoint"] == base <> "/oauth/token"
      assert body["registration_endpoint"] == base <> "/oauth/register"
      assert body["revocation_endpoint"] == base <> "/oauth/revoke"

      # S256 only — no `plain` to downgrade to.
      assert body["code_challenge_methods_supported"] == ["S256"]
      # `"none"` present AND the CIMD flag: both, or Claude never offers CIMD.
      assert "none" in body["token_endpoint_auth_methods_supported"]
      assert body["client_id_metadata_document_supported"] == true
      assert body["authorization_response_iss_parameter_supported"] == true
      assert body["resource_indicators_supported"] == true
      assert body["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert body["scopes_supported"] == ["mcp", "mcp:admin"]
      # HS256 mode publishes no key set.
      refute Map.has_key?(body, "jwks_uri")
    end

    test "openid-configuration is the same document", %{base: base} do
      assert get_json(base <> "/.well-known/openid-configuration") ==
               get_json(base <> "/.well-known/oauth-authorization-server")
    end

    test "the JWKS endpoint 404s in HS256 mode", %{base: base} do
      assert %{status: 404} = Req.get!(base <> "/oauth/jwks", retry: false)
    end

    test "protected-resource metadata byte-matches each mount URL", %{base: base} do
      root = get_json(base <> "/.well-known/oauth-protected-resource/mcp")
      learning = get_json(base <> "/.well-known/oauth-protected-resource/mcp/learning")

      assert root["resource"] == base <> "/mcp"
      assert learning["resource"] == base <> "/mcp/learning"
      # Exactly one authorization server: Claude reads [0] and does not fall back.
      assert root["authorization_servers"] == [base]
      assert learning["authorization_servers"] == [base]
    end

    test "an unauthenticated MCP request answers 401 with a resource_metadata challenge", %{
      base: base
    } do
      response = Req.post!(base <> "/mcp/learning", json: initialize(), retry: false)

      # A 404 here means router order is wrong; a 200 means auth is not wired.
      assert response.status == 401

      challenge =
        response
        |> Req.Response.get_header("www-authenticate")
        |> List.first()
        |> Noizu.MCP.Auth.WWWAuthenticate.parse()

      assert challenge.params["resource_metadata"] ==
               base <> "/.well-known/oauth-protected-resource/mcp/learning"

      assert challenge.params["scope"] == "mcp"
      refute Map.has_key?(challenge.params, "error")
    end
  end

  # ── the full flow ────────────────────────────────────────────────────────

  describe "registration → authorize → token → tools/call → refresh" do
    test "an agent gets from zero to a tool call", %{base: base} do
      client = register(base)
      assert String.starts_with?(client["client_id"], "mcp_")
      assert client["token_endpoint_auth_method"] == "none"
      refute Map.has_key?(client, "client_secret")

      verifier = PKCE.generate_verifier()
      resource = base <> "/mcp/learning"

      {code, state} = authorize(base, client["client_id"], verifier, resource)
      assert state == "client-state-123"

      tokens = exchange(base, client["client_id"], code, verifier, resource)
      assert tokens["token_type"] == "Bearer"
      assert tokens["expires_in"] == 900
      assert tokens["scope"] == "mcp"
      assert is_binary(tokens["refresh_token"])

      # The access token opens the mount it was minted for.
      assert {:ok, session} = mcp_initialize(base, "/mcp/learning", tokens["access_token"])

      assert %{"result" => %{"content" => [%{"text" => "sub=user-1"}]}} =
               mcp_call(base, "/mcp/learning", tokens["access_token"], session)

      # Refresh returns a new pair and retires the old refresh token.
      refreshed = refresh(base, client["client_id"], tokens["refresh_token"])
      assert is_binary(refreshed["access_token"])
      assert refreshed["refresh_token"] != tokens["refresh_token"]
      assert {:ok, _} = mcp_initialize(base, "/mcp/learning", refreshed["access_token"])
    end

    test "the authorization response carries iss (RFC 9207)", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()

      location = run_authorize(base, client["client_id"], verifier, base <> "/mcp/learning")
      query = URI.decode_query(URI.parse(location).query)

      assert query["iss"] == base
      assert is_binary(query["code"])
    end

    test "consent is shown for a self-registered client, and denial redirects", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()
      {:ok, challenge} = PKCE.challenge(verifier)

      page = authorize_page(base, client["client_id"], challenge, base <> "/mcp/learning")
      assert page.status == 200
      assert page.body =~ "wants access to your account"
      # A self-registered client is flagged as such on the screen.
      assert page.body =~ "registered itself"

      form = form_fields(page.body)

      denied =
        Req.post!(base <> "/oauth/consent",
          form: %{
            "login_state" => form["login_state"],
            "csrf_token" => form["csrf_token"],
            "decision" => "deny"
          },
          redirect: false,
          retry: false
        )

      assert denied.status == 302
      location = denied |> Req.Response.get_header("location") |> List.first()
      query = URI.decode_query(URI.parse(location).query)
      assert query["error"] == "access_denied"
      assert query["iss"] == base
      refute Map.has_key?(query, "code")
    end

    test "a second authorization skips consent for a scope already granted", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()

      # First run records consent...
      _ = run_authorize(base, client["client_id"], verifier, base <> "/mcp/learning")

      # ...so the second goes straight to a code.
      {:ok, challenge} = PKCE.challenge(verifier)
      response = authorize_page(base, client["client_id"], challenge, base <> "/mcp/learning")

      assert response.status == 302
      location = response |> Req.Response.get_header("location") |> List.first()
      assert URI.decode_query(URI.parse(location).query)["code"]
    end

    test "a broadened scope re-prompts even with consent on file", %{base: base} do
      # The client must be *registered* for the wider scope, or the second request
      # is refused as invalid_scope before consent is ever considered.
      client = register(base, scope: "mcp mcp:admin")
      verifier = PKCE.generate_verifier()
      _ = run_authorize(base, client["client_id"], verifier, base <> "/mcp/learning")

      {:ok, challenge} = PKCE.challenge(verifier)

      response =
        authorize_page(base, client["client_id"], challenge, base <> "/mcp/learning",
          scope: "mcp mcp:admin"
        )

      assert response.status == 200
      assert response.body =~ "wants access to your account"
    end

    test "an unauthenticated user is redirected to the host login and comes back", %{base: base} do
      client = register(base)
      Fixtures.AS.put(:subject, nil)

      {:ok, challenge} = PKCE.challenge(PKCE.generate_verifier())
      response = authorize_page(base, client["client_id"], challenge, base <> "/mcp/learning")

      assert response.status == 302
      location = response |> Req.Response.get_header("location") |> List.first()
      assert location =~ "/fixture-login?return_to="

      # The return_to is same-origin with the issuer and carries only a state key.
      return_to = URI.decode_query(URI.parse(location).query)["return_to"]
      assert String.starts_with?(return_to, base <> "/oauth/authorize?login_state=")

      # After logging in, that URL resumes the flow.
      Fixtures.AS.put(:subject, "user-1")
      resumed = Req.get!(return_to, redirect: false, retry: false)
      assert resumed.status == 200
      assert resumed.body =~ "wants access to your account"
    end
  end

  # ── audience binding: the headline ───────────────────────────────────────

  describe "audience binding across mounts" do
    test "a token for /mcp is REJECTED at /mcp/learning, and the reverse", %{base: base} do
      client = register(base)

      root_token = full_flow(base, client["client_id"], base <> "/mcp")
      learning_token = full_flow(base, client["client_id"], base <> "/mcp/learning")

      # Each opens its own mount.
      assert {:ok, _} = mcp_initialize(base, "/mcp", root_token)
      assert {:ok, _} = mcp_initialize(base, "/mcp/learning", learning_token)

      # And neither opens the other's.
      assert {:error, 401} = mcp_initialize(base, "/mcp/learning", root_token)
      assert {:error, 401} = mcp_initialize(base, "/mcp", learning_token)
    end

    test "a resource outside the configured list is invalid_target", %{base: base} do
      client = register(base)
      {:ok, challenge} = PKCE.challenge(PKCE.generate_verifier())

      response =
        authorize_page(base, client["client_id"], challenge, "https://evil.example/mcp")

      assert response.status == 302
      location = response |> Req.Response.get_header("location") |> List.first()
      assert URI.decode_query(URI.parse(location).query)["error"] == "invalid_target"
    end

    test "the token endpoint refuses to re-target a code to another resource", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()
      {code, _state} = authorize(base, client["client_id"], verifier, base <> "/mcp/learning")

      response =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client["client_id"],
            "code" => code,
            "code_verifier" => verifier,
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
            # The audience was fixed at authorization time.
            "resource" => base <> "/mcp"
          },
          retry: false
        )

      assert response.status == 400
      assert decoded(response)["error"] == "invalid_target"
    end
  end

  # ── replay and rotation ──────────────────────────────────────────────────

  describe "replay detection" do
    test "redeeming a code twice fails and revokes the family", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()
      resource = base <> "/mcp/learning"
      {code, _state} = authorize(base, client["client_id"], verifier, resource)

      tokens = exchange(base, client["client_id"], code, verifier, resource)

      second =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client["client_id"],
            "code" => code,
            "code_verifier" => verifier,
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"
          },
          retry: false
        )

      assert second.status == 400
      assert decoded(second)["error"] == "invalid_grant"

      # The refresh token from the first (legitimate) exchange is collateral: we
      # cannot tell which caller was the attacker, so the family goes.
      assert %{status: 400} = raw_refresh(base, client["client_id"], tokens["refresh_token"])
    end

    test "reusing a rotated refresh token revokes the whole family", %{base: base} do
      client = register(base)
      resource = base <> "/mcp/learning"
      verifier = PKCE.generate_verifier()
      {code, _state} = authorize(base, client["client_id"], verifier, resource)
      tokens = exchange(base, client["client_id"], code, verifier, resource)

      rotated = refresh(base, client["client_id"], tokens["refresh_token"])

      # Replay of the retired token.
      assert %{status: 400} = raw_refresh(base, client["client_id"], tokens["refresh_token"])

      # And the token it was rotated into is dead too — that is the family
      # revocation, and it is what forces a re-authorization.
      assert %{status: 400} = raw_refresh(base, client["client_id"], rotated["refresh_token"])
    end

    test "a PKCE verifier mismatch is invalid_grant and burns the code", %{base: base} do
      client = register(base)
      resource = base <> "/mcp/learning"
      verifier = PKCE.generate_verifier()
      {code, _state} = authorize(base, client["client_id"], verifier, resource)

      wrong =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client["client_id"],
            "code" => code,
            "code_verifier" => PKCE.generate_verifier(),
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"
          },
          retry: false
        )

      assert wrong.status == 400
      assert decoded(wrong)["error"] == "invalid_grant"

      # The code was consumed by the failed attempt; the real client cannot use it
      # either, which is correct — it may have been stolen.
      second =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client["client_id"],
            "code" => code,
            "code_verifier" => verifier,
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"
          },
          retry: false
        )

      assert second.status == 400
    end
  end

  # ── CIMD ─────────────────────────────────────────────────────────────────

  describe "CIMD variant" do
    setup %{base: base} do
      Fixtures.AS.put_cimd_document(%{
        "client_id" => "https://public.example.com/mcp-client",
        "client_name" => "Fixture CIMD client",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "token_endpoint_auth_method" => "none"
      })

      %{base: base, client_id: "https://public.example.com/mcp-client"}
    end

    test "a URL client_id runs the same flow, with no registration step", %{
      base: base,
      client_id: client_id
    } do
      # The fetcher is injected for the test; the SSRF guard still runs first, with
      # a stub resolver that maps this host to a public address.
      state = Fixtures.AS.state()
      on_exit(fn -> Fixtures.AS.put(:cimd_document, state.cimd_document) end)

      with_cimd_fetcher(fn ->
        token = full_flow(base, client_id, base <> "/mcp/learning")
        assert {:ok, _} = mcp_initialize(base, "/mcp/learning", token)
      end)
    end

    test "a document asserting a different client_id is refused", %{
      base: base,
      client_id: client_id
    } do
      Fixtures.AS.put_cimd_document(%{
        "client_id" => "https://public.example.com/someone-else",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })

      with_cimd_fetcher(fn ->
        {:ok, challenge} = PKCE.challenge(PKCE.generate_verifier())
        response = authorize_page(base, client_id, challenge, base <> "/mcp/learning")

        # Rendered, not redirected: without a resolved client there is no URI we
        # are allowed to send anything to.
        assert response.status == 400
        assert response.body =~ "could not be authorized"
        assert Req.Response.get_header(response, "location") == []
      end)
    end
  end

  # ── the API-key endpoint ─────────────────────────────────────────────────

  describe "api key token endpoint" do
    test "trades a host API key for an audience-bound token, with no refresh", %{base: base} do
      response =
        Req.post!(base <> "/api/mcp/token",
          form: %{"resource" => base <> "/mcp/learning"},
          headers: [{"authorization", "Bearer " <> Fixtures.OAuth.api_key()}],
          retry: false
        )

      assert response.status == 200
      body = decoded(response)
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 900
      # The API key *is* the long-lived credential; a refresh token would be a
      # second one to leak.
      refute Map.has_key?(body, "refresh_token")

      assert {:ok, _} = mcp_initialize(base, "/mcp/learning", body["access_token"])
      # Still audience-bound.
      assert {:error, 401} = mcp_initialize(base, "/mcp", body["access_token"])
    end

    test "a bad key is invalid_client and says nothing more", %{base: base} do
      response =
        Req.post!(base <> "/api/mcp/token",
          form: %{"resource" => base <> "/mcp"},
          headers: [{"authorization", "Bearer mcp_live_wrong"}],
          retry: false
        )

      assert response.status == 401
      body = decoded(response)
      assert body["error"] == "invalid_client"
      refute body["error_description"] =~ "mcp_live_wrong"
    end
  end

  # ── open-redirect discipline ─────────────────────────────────────────────

  describe "open-redirect discipline" do
    test "an unknown client_id renders, never redirects", %{base: base} do
      response =
        Req.get!(
          base <>
            "/oauth/authorize?response_type=code&client_id=nope&redirect_uri=" <>
            URI.encode_www_form("https://evil.example/cb") <>
            "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256",
          redirect: false,
          retry: false
        )

      # 400, not 401: a 401 on an HTML endpoint makes a browser pop its own
      # basic-auth dialog, and there is no `WWW-Authenticate` scheme to satisfy.
      assert response.status == 400
      assert Req.Response.get_header(response, "location") == []
      assert response.body =~ "could not be authorized"
    end

    test "an unregistered redirect_uri renders, never redirects", %{base: base} do
      client = register(base)

      response =
        Req.get!(
          base <>
            "/oauth/authorize?response_type=code&client_id=#{client["client_id"]}&redirect_uri=" <>
            URI.encode_www_form("https://evil-claude.ai/cb") <>
            "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256",
          redirect: false,
          retry: false
        )

      assert response.status == 400
      assert Req.Response.get_header(response, "location") == []
    end

    test "no PKCE is invalid_request, at the redirect URI", %{base: base} do
      client = register(base)

      response =
        Req.get!(
          base <>
            "/oauth/authorize?response_type=code&client_id=#{client["client_id"]}&redirect_uri=" <>
            URI.encode_www_form("https://claude.ai/api/mcp/auth_callback"),
          redirect: false,
          retry: false
        )

      assert response.status == 302
      location = response |> Req.Response.get_header("location") |> List.first()
      assert URI.decode_query(URI.parse(location).query)["error"] == "invalid_request"
    end
  end

  describe "cache-control" do
    test "token, register and revoke responses are never cacheable", %{base: base} do
      client = register(base)
      verifier = PKCE.generate_verifier()
      resource = base <> "/mcp/learning"
      {code, _state} = authorize(base, client["client_id"], verifier, resource)

      token_response =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client["client_id"],
            "code" => code,
            "code_verifier" => verifier,
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"
          },
          retry: false
        )

      assert Req.Response.get_header(token_response, "cache-control") == ["no-store"]

      registration = Req.post!(base <> "/oauth/register", json: registration_body(), retry: false)
      assert Req.Response.get_header(registration, "cache-control") == ["no-store"]

      revocation =
        Req.post!(base <> "/oauth/revoke",
          form: %{"client_id" => client["client_id"], "token" => "whatever"},
          retry: false
        )

      assert revocation.status == 200
      assert Req.Response.get_header(revocation, "cache-control") == ["no-store"]
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp with_cimd_fetcher(fun) do
    # `AS.config/0` is rebuilt per request, so the fetcher is swapped in by
    # pointing the config's cimd opts at the fixture. Simplest route: set it on
    # the persistent state the config reads.
    previous = Application.get_env(:noizu_mcp, :test_cimd_fetcher)
    Application.put_env(:noizu_mcp, :test_cimd_fetcher, &Fixtures.AS.fetch_cimd/2)

    try do
      fun.()
    after
      Application.put_env(:noizu_mcp, :test_cimd_fetcher, previous)
    end
  end

  defp registration_body(opts \\ []) do
    %{
      "client_name" => "E2E agent",
      "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none",
      "scope" => Keyword.get(opts, :scope, "mcp")
    }
  end

  defp register(base, opts \\ []) do
    response = Req.post!(base <> "/oauth/register", json: registration_body(opts), retry: false)
    assert response.status == 201
    decoded(response)
  end

  defp authorize_page(base, client_id, challenge, resource, opts \\ []) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => Keyword.get(opts, :scope, "mcp"),
        "state" => "client-state-123",
        "resource" => resource
      })

    Req.get!(base <> "/oauth/authorize?" <> query, redirect: false, retry: false)
  end

  # The whole browser leg: authorize, approve, and return the redirect Location.
  defp run_authorize(base, client_id, verifier, resource, opts \\ []) do
    {:ok, challenge} = PKCE.challenge(verifier)
    page = authorize_page(base, client_id, challenge, resource, opts)

    case page.status do
      302 ->
        page |> Req.Response.get_header("location") |> List.first()

      200 ->
        form = form_fields(page.body)

        approved =
          Req.post!(base <> "/oauth/consent",
            form: %{
              "login_state" => form["login_state"],
              "csrf_token" => form["csrf_token"],
              "decision" => "approve"
            },
            redirect: false,
            retry: false
          )

        assert approved.status == 302, "consent should redirect, got #{approved.status}"
        approved |> Req.Response.get_header("location") |> List.first()
    end
  end

  defp authorize(base, client_id, verifier, resource, opts \\ []) do
    location = run_authorize(base, client_id, verifier, resource, opts)
    query = URI.decode_query(URI.parse(location).query)
    assert is_binary(query["code"]), "expected a code, got #{location}"
    {query["code"], query["state"]}
  end

  defp exchange(base, client_id, code, verifier, resource) do
    response =
      Req.post!(base <> "/oauth/token",
        form: %{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => code,
          "code_verifier" => verifier,
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
          "resource" => resource
        },
        retry: false
      )

    assert response.status == 200, "token exchange failed: #{inspect(response.body)}"
    decoded(response)
  end

  defp full_flow(base, client_id, resource) do
    verifier = PKCE.generate_verifier()
    {code, _state} = authorize(base, client_id, verifier, resource)
    exchange(base, client_id, code, verifier, resource)["access_token"]
  end

  defp raw_refresh(base, client_id, refresh_token) do
    Req.post!(base <> "/oauth/token",
      form: %{
        "grant_type" => "refresh_token",
        "client_id" => client_id,
        "refresh_token" => refresh_token
      },
      retry: false
    )
  end

  defp refresh(base, client_id, refresh_token) do
    response = raw_refresh(base, client_id, refresh_token)
    assert response.status == 200, "refresh failed: #{inspect(response.body)}"
    decoded(response)
  end

  defp form_fields(html) do
    ~r/name="(?<name>[^"]+)" value="(?<value>[^"]*)"/
    |> Regex.scan(html, capture: :all_names)
    |> Map.new(fn [name, value] -> {name, value} end)
  end

  defp initialize do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "e2e", "version" => "1.0.0"}
      }
    }
  end

  defp mcp_initialize(base, path, token) do
    response =
      Req.post!(base <> path,
        json: initialize(),
        headers: [{"authorization", "Bearer " <> token}],
        retry: false
      )

    case response.status do
      200 -> {:ok, response |> Req.Response.get_header("mcp-session-id") |> List.first()}
      status -> {:error, status}
    end
  end

  defp mcp_call(base, path, token, session) do
    Req.post!(base <> path,
      json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      headers: [{"authorization", "Bearer " <> token}, {"mcp-session-id", session}],
      retry: false
    )

    response =
      Req.post!(base <> path,
        json: %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "whoami", "arguments" => %{}}
        },
        headers: [{"authorization", "Bearer " <> token}, {"mcp-session-id", session}],
        retry: false
      )

    decoded(response)
  end

  defp get_json(url) do
    response = Req.get!(url, retry: false)
    assert response.status == 200
    decoded(response)
  end

  # Req decodes a JSON body for us; a raw binary comes back for text/html.
  defp decoded(%Req.Response{body: body}) when is_map(body), do: body
  defp decoded(%Req.Response{body: body}), do: Jason.decode!(body)
end
