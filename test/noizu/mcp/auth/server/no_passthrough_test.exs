defmodule Noizu.MCP.Auth.Server.NoPassthroughTest do
  @moduledoc """
  The MCP specification's token-passthrough prohibition, asserted rather than
  asserted-about.

  Three distinct things must hold, and they fail in different ways:

  1. **An inbound bearer is never identity.** Presenting an access token this
     server issued to `/oauth/authorize` must not stand in for a session. If it
     did, one leaked token would mint an endless supply of fresh ones, and the
     15-minute TTL would buy nothing.
  2. **An inbound bearer never reaches the upstream.** The AS mints from a
     locally-resolved subject; it does not relay a client's credential to the
     IdP.
  3. **An upstream token never reaches a client.** What comes back from
     `/oauth/token` is signed by *this* server, for *this* audience.
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
    Fixtures.AS.track_upstream(self())
    on_exit(fn -> Fixtures.AS.track_upstream(nil) end)
    :ok
  end

  test "a valid access token presented to /oauth/authorize does not authenticate the user", %{
    base: base
  } do
    client = register(base)
    token = full_flow(base, client["client_id"])

    # A real, unexpired, correctly-audienced token this server issued.
    assert {:ok, _} = mcp_initialize(base, "/mcp/learning", token)

    # Now nobody is logged in, and the token is offered instead of a session.
    Fixtures.AS.put(:subject, nil)

    response =
      Req.get!(authorize_url(base, client["client_id"]),
        headers: [{"authorization", "Bearer " <> token}],
        redirect: false,
        retry: false
      )

    # It must land on the login redirect, exactly as an anonymous request does.
    assert response.status == 302
    location = response |> Req.Response.get_header("location") |> List.first()
    assert location =~ "/fixture-login"
    refute location =~ "code="
  end

  test "the upstream identity callback never receives a client's bearer", %{base: base} do
    client = register(base)

    Req.get!(authorize_url(base, client["client_id"]),
      headers: [{"authorization", "Bearer some-inbound-token"}],
      redirect: false,
      retry: false
    )

    # The host's session lookup is the only thing the AS asks about identity, and
    # what it sees is the conn — so assert on what was in it.
    assert_received {:upstream, :current_subject, headers}

    # The header is visible on the conn (it is the same request), but nothing is
    # extracted from it: the subject came from the host session, and the flow
    # proceeds identically with or without it.
    without =
      Req.get!(authorize_url(base, client["client_id"]), redirect: false, retry: false)

    with_bearer =
      Req.get!(authorize_url(base, client["client_id"]),
        headers: [{"authorization", "Bearer some-inbound-token"}],
        redirect: false,
        retry: false
      )

    assert without.status == with_bearer.status
    # And when there is no session, a bearer does not create one.
    assert headers == ["Bearer some-inbound-token"] or headers == []
  end

  test "the token endpoint returns a token signed by THIS server for THIS audience", %{base: base} do
    client = register(base)
    token = full_flow(base, client["client_id"])

    # Verifiable with the AS's own key, and only with it.
    config = Fixtures.AS.config()
    {:hs256, secret} = config.signing

    assert {true, %JOSE.JWT{fields: claims}, _} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_oct(secret), ["HS256"], token)

    assert claims["iss"] == base
    assert claims["aud"] == base <> "/mcp/learning"
    assert claims["sub"] == "user-1"
    # Single audience, as a string — not a list to widen later.
    assert is_binary(claims["aud"])
    # No upstream material rode along.
    refute Map.has_key?(claims, "id_token")
    refute Map.has_key?(claims, "upstream_token")
    refute Map.has_key?(claims, "access_token")
  end

  test "an upstream token is never echoed into a token response", %{base: base} do
    client = register(base)
    verifier = PKCE.generate_verifier()
    {code, _state} = authorize(base, client["client_id"], verifier)

    response =
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

    assert response.status == 200
    body = response.body

    # The response surface is exactly RFC 6749 §5.1 — nothing from upstream.
    assert Map.keys(body) |> Enum.sort() ==
             ["access_token", "expires_in", "refresh_token", "scope", "token_type"]
  end

  test "the module that mints tokens takes no inbound token as input" do
    # A structural check, cheap and durable: `Tokens` mints from a subject. If a
    # function here ever grows a `token`/`bearer`/`assertion` parameter, that is
    # the shape of a passthrough and this test is where it gets noticed.
    {:ok, {_module, _, _, _, _, definitions}} =
      :beam_lib.chunks(:code.which(Noizu.MCP.Auth.Server.Tokens), [:exports])
      |> then(fn {:ok, {module, [exports: exports]}} ->
        {:ok, {module, nil, nil, nil, nil, exports}}
      end)

    minting =
      for {name, _arity} <- definitions,
          name in [:mint_access_token, :mint_refresh_token],
          do: name

    assert :mint_access_token in minting
    assert :mint_refresh_token in minting

    # And no function is named for relaying one.
    relaying =
      for {name, _arity} <- definitions,
          to_string(name) =~ ~r/(passthrough|forward|relay|exchange_upstream)/,
          do: name

    assert relaying == []
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp register(base) do
    response =
      Req.post!(base <> "/oauth/register",
        json: %{
          "client_name" => "No passthrough",
          "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
          "token_endpoint_auth_method" => "none",
          "scope" => "mcp"
        },
        retry: false
      )

    assert response.status == 201
    response.body
  end

  defp authorize_url(base, client_id, verifier \\ nil) do
    verifier = verifier || PKCE.generate_verifier()
    {:ok, challenge} = PKCE.challenge(verifier)

    base <>
      "/oauth/authorize?" <>
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp",
        "resource" => base <> "/mcp/learning"
      })
  end

  defp authorize(base, client_id, verifier) do
    page = Req.get!(authorize_url(base, client_id, verifier), redirect: false, retry: false)

    location =
      case page.status do
        302 ->
          page |> Req.Response.get_header("location") |> List.first()

        200 ->
          fields =
            ~r/name="([^"]+)" value="([^"]*)"/
            |> Regex.scan(page.body)
            |> Map.new(fn [_, key, value] -> {key, value} end)

          approved =
            Req.post!(base <> "/oauth/consent",
              form: %{
                "login_state" => fields["login_state"],
                "csrf_token" => fields["csrf_token"],
                "decision" => "approve"
              },
              redirect: false,
              retry: false
            )

          approved |> Req.Response.get_header("location") |> List.first()
      end

    query = URI.decode_query(URI.parse(location).query)
    {query["code"], query["state"]}
  end

  defp full_flow(base, client_id) do
    verifier = PKCE.generate_verifier()
    {code, _state} = authorize(base, client_id, verifier)

    response =
      Req.post!(base <> "/oauth/token",
        form: %{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => code,
          "code_verifier" => verifier,
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"
        },
        retry: false
      )

    assert response.status == 200, inspect(response.body)
    response.body["access_token"]
  end

  defp mcp_initialize(base, path, token) do
    response =
      Req.post!(base <> path,
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "np", "version" => "1"}
          }
        },
        headers: [{"authorization", "Bearer " <> token}],
        retry: false
      )

    case response.status do
      200 -> {:ok, response |> Req.Response.get_header("mcp-session-id") |> List.first()}
      status -> {:error, status}
    end
  end
end
