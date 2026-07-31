defmodule Noizu.MCP.Auth.Server.CIMDTest do
  @moduledoc """
  The CIMD fetch dereferences a URL the client chose, so what matters is what the
  fetch refuses and what it does with a stale or hostile document.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.CIMD
  alias Noizu.MCP.Auth.Server.Client
  alias Noizu.MCP.Auth.Server.Errors
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Fixtures.OAuth

  @client_id "https://public.example.com/mcp-client"

  @document %{
    "client_id" => @client_id,
    "client_name" => "Fixture agent",
    "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
  }

  defp config(overrides \\ []) do
    cimd =
      Keyword.merge(
        [
          enabled: true,
          ssrf: [resolver: &OAuth.resolver/1],
          fetcher: fn _url, _opts ->
            {:ok, %{status: 200, body: @document, headers: %{"etag" => ~s("v1")}}}
          end
        ],
        Keyword.get(overrides, :cimd, [])
      )

    Server.config(
      Keyword.merge(
        [
          issuer: "https://app.example.com",
          store: {Store.ETS, name: :unused},
          signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []}
        ],
        Keyword.put(overrides, :cimd, cimd)
      )
    )
  end

  describe "cimd_client_id?/1" do
    test "an https URL is a CIMD client_id; nothing else is" do
      assert CIMD.cimd_client_id?("https://claude.ai/client")
      refute CIMD.cimd_client_id?("http://claude.ai/client")
      refute CIMD.cimd_client_id?("mcp_abc123")
      refute CIMD.cimd_client_id?(nil)
    end
  end

  describe "resolve/3" do
    test "fetches and builds a client" do
      assert {:ok, client, :fetched} = CIMD.resolve(@client_id, nil, config())
      assert client.client_id == @client_id
      assert client.client_id_kind == :cimd
      assert client.cimd_etag == ~s("v1")
    end

    test "serves a fresh cached document without fetching" do
      raising = [cimd: [fetcher: fn _url, _opts -> raise "should not fetch" end]]
      {:ok, cached, :fetched} = CIMD.resolve(@client_id, nil, config())

      assert {:ok, ^cached, :cached} = CIMD.resolve(@client_id, cached, config(raising))
    end

    test "re-fetches a stale document" do
      {:ok, cached, _} = CIMD.resolve(@client_id, nil, config())
      stale = %{cached | cimd_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}

      assert {:ok, _client, :fetched} = CIMD.resolve(@client_id, stale, config())
    end

    test "a 304 extends the cached document rather than discarding it" do
      {:ok, cached, _} = CIMD.resolve(@client_id, nil, config())
      stale = %{cached | cimd_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}

      config = config(cimd: [fetcher: fn _url, _opts -> {:not_modified, ~s("v2")} end])

      assert {:ok, refreshed, :fetched} = CIMD.resolve(@client_id, stale, config)
      assert refreshed.client_name == cached.client_name
      assert refreshed.cimd_etag == ~s("v2")
      assert DateTime.compare(refreshed.cimd_expires_at, DateTime.utc_now()) == :gt
    end

    test "a transient failure keeps serving the cached document" do
      # A DNS blip must not lock every agent out.
      {:ok, cached, _} = CIMD.resolve(@client_id, nil, config())
      stale = %{cached | cimd_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      config = config(cimd: [fetcher: fn _url, _opts -> {:error, :timeout} end])

      log =
        capture_log(fn ->
          assert {:ok, served, :cached} = CIMD.resolve(@client_id, stale, config)
          assert served.client_name == cached.client_name
        end)

      assert log =~ "serving the cached document"
    end

    test "a failure with no cache is invalid_client" do
      config = config(cimd: [fetcher: fn _url, _opts -> {:error, :timeout} end])
      assert {:error, %Errors{code: :invalid_client}} = CIMD.resolve(@client_id, nil, config)
    end

    test "disabled CIMD refuses outright" do
      assert {:error, %Errors{code: :invalid_client}} =
               CIMD.resolve(@client_id, nil, config(cimd: [enabled: false]))
    end

    test "a non-URL client_id is not a CIMD client" do
      assert {:error, %Errors{code: :invalid_client}} = CIMD.resolve("mcp_abc", nil, config())
    end
  end

  describe "the SSRF guard runs before the fetcher" do
    test "an internal address is refused, and the fetcher never runs" do
      config =
        config(cimd: [fetcher: fn _url, _opts -> raise "the guard should have stopped this" end])

      log =
        capture_log(fn ->
          for url <- [
                "https://metadata.example.com/client",
                "https://internal.example.com/client",
                "https://mapped.example.com/client",
                "https://169.254.169.254/client",
                "https://[::1]/client"
              ] do
            assert {:error, %Errors{code: :invalid_client, reason: {:ssrf, _}}} =
                     CIMD.resolve(url, nil, config)
          end
        end)

      assert log =~ "refused by the SSRF guard"
    end

    test "http, a non-443 port and userinfo are all refused" do
      config = config(cimd: [fetcher: fn _url, _opts -> raise "unreachable" end])

      # `http://` is not even a CIMD client_id, so it fails earlier — but these
      # https variants have to be caught by the guard.
      for url <- [
            "https://public.example.com:8443/client",
            "https://user:pw@public.example.com/client"
          ] do
        assert {:error, %Errors{code: :invalid_client}} = CIMD.resolve(url, nil, config)
      end
    end

    test "the error never says why — the caller learns only invalid_client" do
      config = config(cimd: [fetcher: fn _url, _opts -> {:error, :nope} end])

      capture_log(fn ->
        {:error, error} = CIMD.resolve("https://metadata.example.com/client", nil, config)
        rendered = Errors.to_map(error)

        refute rendered["error_description"] =~ "169.254"
        refute rendered["error_description"] =~ "ssrf"
        refute rendered["error_description"] =~ "metadata"
      end)
    end
  end

  describe "document validation" do
    test "a document asserting another client_id is refused" do
      config =
        config(
          cimd: [
            fetcher: fn _url, _opts ->
              {:ok,
               %{
                 status: 200,
                 body: Map.put(@document, "client_id", "https://elsewhere/x"),
                 headers: %{}
               }}
            end
          ]
        )

      assert {:error, %Errors{code: :invalid_client_metadata}} =
               CIMD.resolve(@client_id, nil, config)
    end

    test "a non-200 or malformed response is refused" do
      for response <- [
            {:ok, %{status: 404, body: %{}, headers: %{}}},
            {:ok, %{status: 200, body: "not a map", headers: %{}}},
            :nonsense
          ] do
        config = config(cimd: [fetcher: fn _url, _opts -> response end])
        assert {:error, %Errors{}} = CIMD.resolve(@client_id, nil, config)
      end
    end

    test "a raising fetcher is contained" do
      config = config(cimd: [fetcher: fn _url, _opts -> raise "boom" end])

      log =
        capture_log(fn ->
          assert {:error, %Errors{code: :invalid_client}} = CIMD.resolve(@client_id, nil, config)
        end)

      assert log =~ "CIMD fetcher raised"
    end

    test "a {module, opts} fetcher is supported" do
      config = config(cimd: [fetcher: {__MODULE__.StubFetcher, []}])
      assert {:ok, client, :fetched} = CIMD.resolve(@client_id, nil, config)
      assert client.client_name == "Stub module"
    end
  end

  describe "resolve_client/2 integration" do
    setup do
      name = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
      start_supervised!({Store.ETS, name: name})
      %{store: [name: name]}
    end

    test "caches the fetched document so the next request does not refetch", %{store: store} do
      config = config(store: {Store.ETS, store})

      assert {:ok, client} = Server.resolve_client(config, @client_id)
      assert client.client_id_kind == :cimd

      # It is now in the store, and a fetcher that raises proves it is not refetched.
      raising = config(store: {Store.ETS, store}, cimd: [fetcher: fn _u, _o -> raise "no" end])
      assert {:ok, _cached} = Server.resolve_client(raising, @client_id)
    end

    test "an unknown non-URL client_id is invalid_client", %{store: store} do
      config = config(store: {Store.ETS, store})
      assert {:error, %Errors{code: :invalid_client}} = Server.resolve_client(config, "mcp_nope")
      assert {:error, %Errors{code: :invalid_client}} = Server.resolve_client(config, nil)
    end

    test "a disabled client is refused even though it resolves", %{store: store} do
      config = config(store: {Store.ETS, store})

      {:ok, _} =
        Store.ETS.put_client(
          %Client{client_id: "mcp_off", disabled_at: DateTime.utc_now()},
          store
        )

      assert {:error, %Errors{code: :invalid_client, reason: :client_disabled}} =
               Server.resolve_client(config, "mcp_off")
    end
  end

  defmodule StubFetcher do
    @moduledoc false
    def fetch(_url, _opts) do
      {:ok,
       %{
         status: 200,
         body: %{
           "client_id" => "https://public.example.com/mcp-client",
           "client_name" => "Stub module",
           "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
         },
         headers: %{}
       }}
    end
  end
end
