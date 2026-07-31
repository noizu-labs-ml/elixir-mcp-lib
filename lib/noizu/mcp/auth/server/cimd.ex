defmodule Noizu.MCP.Auth.Server.CIMD do
  @moduledoc """
  Client-ID Metadata Documents: a `client_id` that is itself an https URL serving
  the client's own metadata.

  This is how claude.ai avoids registering with every MCP server it meets — and
  the only reason it is safe is that the fetch is fenced. The URL is chosen by
  whoever is calling, so `Noizu.MCP.Auth.Server.SSRF` runs first on every fetch:
  https only, port 443, every resolved address public (IPv4, IPv6 and
  v4-mapped-v6, `169.254.169.254` included), no redirects followed, 64 KiB cap,
  5 s timeout.

  Claude only *offers* CIMD when the metadata document advertises both
  `client_id_metadata_document_supported: true` and `"none"` in
  `token_endpoint_auth_methods_supported`; `MetadataPlug` emits both when
  `cimd: [enabled: true]`.

  ## The fetcher is injectable

      cimd: [enabled: true, fetcher: {MyApp.Fetcher, []}]

  Defaults to `Noizu.MCP.Auth.Server.CIMD.ReqFetcher` when `:req` is available.
  A fetcher receives `(url, opts)` and must honour `Noizu.MCP.Auth.Server.SSRF.fetch_opts/0`
  — the caps are the security property, not a suggestion.

  ## Caching

  A fetched document is stored as a `:cimd` client with `cimd_expires_at`; a stale
  entry is re-fetched with `If-None-Match` and a `304` just extends it. A fetch
  failure with a **cached** document still in hand keeps the cached one: a
  transient DNS blip should not lock every agent out.
  """

  require Logger

  alias Noizu.MCP.Auth.Server.Client
  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Errors
  alias Noizu.MCP.Auth.Server.SSRF

  @typedoc """
  A fetcher's answer. `{:ok, %{status:, body:, headers:}}`, where `body` is a
  decoded map, or `{:not_modified, etag}` for a 304.
  """
  @type response ::
          {:ok, %{status: pos_integer(), body: map(), headers: map()}}
          | {:not_modified, String.t() | nil}
          | {:error, term()}

  @doc "True when `client_id` looks like a CIMD URL rather than a registered id."
  @spec cimd_client_id?(term()) :: boolean()
  def cimd_client_id?(client_id) when is_binary(client_id),
    do: String.starts_with?(client_id, "https://")

  def cimd_client_id?(_client_id), do: false

  @doc """
  Resolve a CIMD `client_id` to a `Client`, fetching if there is no fresh cached
  document.

  Returns `{:ok, client, :cached | :fetched}` so the caller knows whether to
  persist.
  """
  @spec resolve(String.t(), Client.t() | nil, Config.t()) ::
          {:ok, Client.t(), :cached | :fetched} | {:error, Errors.t()}
  def resolve(client_id, cached, %Config{} = config) do
    cond do
      not Noizu.MCP.Auth.Server.cimd_enabled?(config) ->
        {:error, Errors.new(:invalid_client, reason: :cimd_disabled)}

      not cimd_client_id?(client_id) ->
        {:error, Errors.new(:invalid_client, reason: :not_a_cimd_client_id)}

      cached && not Client.cimd_stale?(cached, DateTime.utc_now()) ->
        {:ok, cached, :cached}

      true ->
        fetch_and_build(client_id, cached, config)
    end
  end

  @doc """
  Fetch and validate a document, ignoring any cache. Returns the `Client` built
  from it.
  """
  @spec fetch(String.t(), Client.t() | nil, Config.t()) ::
          {:ok, Client.t()} | {:error, Errors.t()}
  def fetch(client_id, cached, %Config{} = config) do
    with {:ok, _checked} <- guard(client_id, config),
         {:ok, response} <- request(client_id, cached, config) do
      case response do
        {:not_modified, etag} when not is_nil(cached) ->
          {:ok, refresh_cached(cached, etag, config)}

        %{status: 200, body: body, headers: headers} when is_map(body) ->
          with {:ok, client} <- Client.from_cimd(client_id, body, config) do
            {:ok, %{client | cimd_etag: headers["etag"]}}
          end

        %{status: status} ->
          {:error, Errors.new(:invalid_client, reason: {:cimd_status, status})}

        _ ->
          {:error, Errors.new(:invalid_client, reason: :cimd_malformed)}
      end
    end
  end

  defp fetch_and_build(client_id, cached, config) do
    case fetch(client_id, cached, config) do
      {:ok, client} ->
        {:ok, client, :fetched}

      {:error, error} when not is_nil(cached) ->
        # A transient failure must not lock out every agent using this client_id.
        Logger.warning(
          "CIMD refresh failed for a cached client (#{inspect(error.reason)}); serving the cached document"
        )

        {:ok, cached, :cached}

      {:error, error} ->
        {:error, error}
    end
  end

  defp guard(client_id, config) do
    case SSRF.check_url(client_id, Keyword.get(config.cimd, :ssrf, [])) do
      {:ok, checked} ->
        {:ok, checked}

      {:error, reason} ->
        # Logged, never rendered: the client learns only `invalid_client`.
        Logger.warning("CIMD fetch refused by the SSRF guard: #{inspect(reason)}")
        {:error, Errors.new(:invalid_client, reason: {:ssrf, reason})}
    end
  end

  defp request(client_id, cached, config) do
    opts =
      SSRF.fetch_opts()
      |> Keyword.put(:etag, cached && cached.cimd_etag)
      |> Keyword.merge(Keyword.get(config.cimd, :fetch_opts, []))

    case fetcher(config) do
      nil ->
        Logger.error(
          "CIMD is enabled but there is no fetcher — add `:req` to your deps or pass cimd: [fetcher: ...]"
        )

        {:error, Errors.new(:temporarily_unavailable, reason: :no_fetcher)}

      {module, fetcher_opts} ->
        invoke(fn -> module.fetch(client_id, Keyword.merge(opts, fetcher_opts)) end)

      fun when is_function(fun, 2) ->
        invoke(fn -> fun.(client_id, opts) end)
    end
  end

  defp invoke(callback) do
    case callback.() do
      {:ok, response} -> {:ok, response}
      {:not_modified, etag} -> {:ok, {:not_modified, etag}}
      {:error, reason} -> {:error, Errors.new(:invalid_client, reason: {:cimd_fetch, reason})}
      _other -> {:error, Errors.new(:invalid_client, reason: :cimd_fetch)}
    end
  rescue
    error ->
      Logger.warning("CIMD fetcher raised #{inspect(error.__struct__)}")
      {:error, Errors.new(:invalid_client, reason: :cimd_fetch)}
  end

  defp refresh_cached(cached, etag, config) do
    now = DateTime.utc_now()
    ttl = Keyword.get(config.cimd, :ttl, 3_600)

    %{
      cached
      | cimd_fetched_at: now,
        cimd_expires_at: DateTime.add(now, ttl, :second),
        cimd_etag: etag || cached.cimd_etag
    }
  end

  defp fetcher(config) do
    case Keyword.get(config.cimd, :fetcher) do
      nil -> default_fetcher()
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
      fun when is_function(fun, 2) -> fun
    end
  end

  defp default_fetcher do
    if Code.ensure_loaded?(Req), do: {Noizu.MCP.Auth.Server.CIMD.ReqFetcher, []}
  end
end
