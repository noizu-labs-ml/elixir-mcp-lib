defmodule Noizu.MCP.Auth.Server.ConfigTest do
  @moduledoc """
  `Auth.Server.config/1` raises rather than warning, because every mistake it
  catches presents in production the same way: every client silently refuses to
  authenticate, with nothing in the logs.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.MetadataPlug
  alias Noizu.MCP.Auth.Server.Store

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        issuer: "https://app.example.com",
        store: {Store.ETS, name: :test_store},
        signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
        upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []}
      ],
      overrides
    )
  end

  describe "issuer" do
    test "normalizes and keeps an origin" do
      assert %Config{issuer: "https://app.example.com"} =
               Server.config(opts(issuer: "HTTPS://App.Example.com:443"))
    end

    test "refuses an issuer with a path — RFC 8414 discovery becomes ambiguous" do
      assert_raise ArgumentError, ~r/origin with no path/, fn ->
        Server.config(opts(issuer: "https://app.example.com/mcp"))
      end
    end

    test "refuses a non-absolute or non-http issuer" do
      for issuer <- ["app.example.com", "", "urn:example", nil] do
        assert_raise ArgumentError, fn -> Server.config(opts(issuer: issuer)) end
      end
    end
  end

  describe "required options" do
    test "store, signing and upstream are all required" do
      assert_raise ArgumentError, ~r/:store is required/, fn ->
        Server.config(opts() |> Keyword.delete(:store))
      end

      assert_raise ArgumentError, ~r/:signing is required/, fn ->
        Server.config(opts() |> Keyword.delete(:signing))
      end

      assert_raise ArgumentError, ~r/:upstream is required/, fn ->
        Server.config(opts() |> Keyword.delete(:upstream))
      end
    end

    test "rs256 requires a key" do
      assert_raise ArgumentError, ~r/requires :jwk/, fn ->
        Server.config(opts(signing: {:rs256, []}))
      end
    end

    test "a bare module is accepted for store and upstream" do
      config =
        Server.config(
          opts(store: Store.ETS, upstream: Noizu.MCP.Auth.Server.Upstream.HostSession)
        )

      # Pinned to the exact opts, not "any opts list". `config/1` copies the
      # server's `:track_access_tokens` into the store options so the two can
      # never disagree; a looser match here would let that copying silently stop
      # happening, which is the drift the copying exists to prevent.
      assert {Store.ETS, [track_access_tokens: false]} = Config.store(config)
    end
  end

  describe "TTLs" do
    test "the access-token TTL is clamped to 15 minutes" do
      # An untracked bearer cannot be revoked, so its lifetime is the whole of
      # its blast radius.
      assert %Config{access_token_ttl: 900} = Server.config(opts(access_token_ttl: 86_400))
      assert %Config{access_token_ttl: 300} = Server.config(opts(access_token_ttl: 300))
    end

    test "defaults are sane" do
      config = Server.config(opts())
      assert config.access_token_ttl == 900
      assert config.refresh_token_ttl == 2_592_000
      assert config.refresh_family_ttl == 7_776_000
      assert config.authorization_code_ttl == 60
      assert config.login_state_ttl == 600
    end

    test "the family TTL may be disabled but not made nonsense" do
      assert %Config{refresh_family_ttl: nil} = Server.config(opts(refresh_family_ttl: nil))

      assert_raise ArgumentError, fn -> Server.config(opts(refresh_family_ttl: 0)) end
      assert_raise ArgumentError, fn -> Server.config(opts(access_token_ttl: -1)) end
      assert_raise ArgumentError, fn -> Server.config(opts(login_state_ttl: "600")) end
    end

    test "the authorization-code TTL is capped: a code should live seconds" do
      assert %Config{authorization_code_ttl: 600} =
               Server.config(opts(authorization_code_ttl: 99_999))
    end
  end

  describe "resources" do
    test "must live under the issuer" do
      assert_raise ArgumentError, ~r/not under issuer/, fn ->
        Server.config(opts(resources: [[resource: "https://other.example.com/mcp"]]))
      end
    end

    test "are normalized and keep their names" do
      config =
        Server.config(
          opts(
            resources: [
              [resource: "https://app.example.com:443/mcp", name: "Root"],
              %{resource: "https://app.example.com/mcp/learning"}
            ]
          )
        )

      assert Config.resource_uris(config) == [
               "https://app.example.com/mcp",
               "https://app.example.com/mcp/learning"
             ]

      assert {:ok, %{name: "Root"}} = Config.resource(config, "https://app.example.com/mcp")
      assert :error = Config.resource(config, "https://app.example.com/mcp/other")
    end

    test "an entry with no :resource is a boot error" do
      assert_raise ArgumentError, fn -> Server.config(opts(resources: [[name: "nope"]])) end
    end
  end

  describe "resolve_resource/2" do
    test "one configured mount is the default audience" do
      config = Server.config(opts(resources: [[resource: "https://app.example.com/mcp"]]))
      assert {:ok, "https://app.example.com/mcp"} = Server.resolve_resource(config, nil)
    end

    test "with several mounts, an absent resource is an error rather than a guess" do
      # Guessing hands out a token for the wrong audience, which then fails at the
      # mount the user was actually trying to reach.
      config =
        Server.config(
          opts(
            resources: [
              [resource: "https://app.example.com/mcp"],
              [resource: "https://app.example.com/mcp/learning"]
            ]
          )
        )

      assert {:error, :invalid_target} = Server.resolve_resource(config, nil)
    end

    test "a resource must be one of the configured mounts" do
      config =
        Server.config(
          opts(
            resources: [
              [resource: "https://app.example.com/mcp"],
              [resource: "https://app.example.com/mcp/learning"]
            ]
          )
        )

      assert {:ok, "https://app.example.com/mcp/learning"} =
               Server.resolve_resource(config, "https://app.example.com/mcp/learning")

      # Normalization applies, but nothing else does.
      assert {:ok, "https://app.example.com/mcp"} =
               Server.resolve_resource(config, "https://APP.example.com:443/mcp")

      for outside <- [
            "https://app.example.com/mcp/other",
            "https://app.example.com/mcp/",
            "https://evil.example/mcp",
            "https://app.example.com",
            :not_a_string
          ] do
        assert {:error, :invalid_target} = Server.resolve_resource(config, outside)
      end
    end

    test "resource_required forces the parameter even with one mount" do
      config =
        Server.config(
          opts(resources: [[resource: "https://app.example.com/mcp"]], resource_required: true)
        )

      assert {:error, :invalid_target} = Server.resolve_resource(config, nil)
      assert {:ok, _} = Server.resolve_resource(config, "https://app.example.com/mcp")
    end

    test "with nothing configured, only an absent resource is allowed" do
      config = Server.config(opts())
      assert {:ok, nil} = Server.resolve_resource(config, nil)

      assert {:error, :invalid_target} =
               Server.resolve_resource(config, "https://app.example.com/mcp")
    end
  end

  describe "endpoint URLs" do
    test "are issuer + path, and overridable" do
      config = Server.config(opts())
      assert Config.url(config, :authorize) == "https://app.example.com/oauth/authorize"
      assert Config.url(config, :token) == "https://app.example.com/oauth/token"
      assert Config.url(config, :api_token) == "https://app.example.com/api/mcp/token"

      custom = Server.config(opts(paths: [token: "/auth/oauth2/token"]))
      assert Config.url(custom, :token) == "https://app.example.com/auth/oauth2/token"
      # Overriding one leaves the rest alone.
      assert Config.url(custom, :authorize) == "https://app.example.com/oauth/authorize"
    end
  end

  describe "the metadata document" do
    test "omits registration_endpoint when DCR is off" do
      config = Server.config(opts())
      document = MetadataPlug.document(config)

      refute Map.has_key?(document, "registration_endpoint")
      refute Server.dcr_enabled?(config)
      # `"none"` is always advertised: an MCP client is a public client with PKCE.
      assert "none" in document["token_endpoint_auth_methods_supported"]
      assert document["client_id_metadata_document_supported"] == false
    end

    test "advertises CIMD only when it is enabled" do
      assert MetadataPlug.document(Server.config(opts(cimd: [enabled: true])))[
               "client_id_metadata_document_supported"
             ] == true
    end

    test "publishes jwks_uri only in RS256 mode" do
      hs = MetadataPlug.document(Server.config(opts()))
      refute Map.has_key?(hs, "jwks_uri")

      rs =
        MetadataPlug.document(
          Server.config(
            opts(signing: {:rs256, jwk: JOSE.JWK.generate_key({:rsa, 2048}), kid: "k1"})
          )
        )

      assert rs["jwks_uri"] == "https://app.example.com/oauth/jwks"
    end

    test "S256 is the only challenge method offered" do
      assert MetadataPlug.document(Server.config(opts()))["code_challenge_methods_supported"] == [
               "S256"
             ]
    end

    test "extra_metadata is merged in last" do
      document =
        MetadataPlug.document(Server.config(opts(extra_metadata: %{"custom_field" => true})))

      assert document["custom_field"] == true
    end
  end

  describe "rate_limit/3" do
    def limiter(endpoint, _conn, _config), do: send(self(), {:limited, endpoint}) && :ok

    test "is :ok with no hook configured" do
      assert :ok = Server.rate_limit(Server.config(opts()), :register, nil)
    end

    test "calls a {module, function} hook" do
      config = Server.config(opts(rate_limit: {__MODULE__, :limiter}))
      assert :ok = Server.rate_limit(config, :register, nil)
      assert_received {:limited, :register}
    end

    test "propagates a refusal" do
      config = Server.config(opts(rate_limit: fn _endpoint, _conn, _config -> {:error, 30} end))
      assert {:error, 30} = Server.rate_limit(config, :token, nil)
    end
  end
end
