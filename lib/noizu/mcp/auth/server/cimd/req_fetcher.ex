if Code.ensure_loaded?(Req) do
  defmodule Noizu.MCP.Auth.Server.CIMD.ReqFetcher do
    @moduledoc """
    Default CIMD fetcher, over `:req`. Used automatically when `:req` is in your
    deps; pass `cimd: [fetcher: ...]` to substitute anything else.

    Every limit `Noizu.MCP.Auth.Server.SSRF.fetch_opts/0` names is enforced here,
    because a fetcher that quietly followed a redirect would undo the address
    check entirely:

      * `redirect: false` — a public URL that 302s to `http://169.254.169.254/`
        is the whole game
      * `max_body` — a 64 KiB cap, checked against `content-length` *and* against
        what actually arrived, since `content-length` is a claim
      * `timeout` — 5 s connect and receive
      * `Accept: application/json` only
    """

    alias Noizu.MCP.Auth.Server.SSRF

    @doc """
    Fetch a client-id metadata document.

    `{:ok, %{status:, body:, headers:}}`, `{:not_modified, etag}` for a 304, or
    `{:error, reason}`.
    """
    @spec fetch(String.t(), keyword()) ::
            {:ok, %{status: pos_integer(), body: map(), headers: map()}}
            | {:not_modified, String.t() | nil}
            | {:error, term()}
    def fetch(url, opts \\ []) do
      max_body = Keyword.get(opts, :max_body, SSRF.max_body())
      timeout = Keyword.get(opts, :timeout, SSRF.timeout())

      headers =
        [{"accept", "application/json"}] ++
          case Keyword.get(opts, :etag) do
            nil -> []
            etag -> [{"if-none-match", etag}]
          end

      request =
        Req.new(
          url: url,
          method: :get,
          headers: headers,
          redirect: false,
          max_redirects: 0,
          receive_timeout: timeout,
          connect_options: [timeout: timeout],
          decode_body: false,
          retry: false
        )

      case Req.request(request) do
        {:ok, %Req.Response{status: 304} = response} ->
          {:not_modified, header(response, "etag")}

        {:ok, %Req.Response{status: 200} = response} ->
          decode(response, max_body)

        {:ok, %Req.Response{status: status}} when status in 300..399 ->
          # Not followed, and not treated as success: the address check applied
          # to the URL we were given, not to wherever this points.
          {:error, {:redirect_not_followed, status}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end

    @doc """
    POST a form and decode the JSON response — the token exchange for
    `Noizu.MCP.Auth.Server.Upstream.OIDC`.
    """
    @spec post_form(String.t(), map()) :: {:ok, map()} | {:error, term()}
    def post_form(url, body) do
      request =
        Req.new(
          url: url,
          method: :post,
          form: body,
          headers: [{"accept", "application/json"}],
          redirect: false,
          receive_timeout: SSRF.timeout(),
          retry: false,
          decode_body: false
        )

      case Req.request(request) do
        {:ok, %Req.Response{status: status, body: raw}} when status in 200..299 ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
            _ -> {:error, :malformed_response}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end

    defp decode(%Req.Response{body: raw} = response, max_body) do
      cond do
        not is_binary(raw) ->
          {:error, :malformed_body}

        # `content-length` is the sender's claim; `byte_size` is the fact. Check
        # both, so a lying header is caught and an unbounded stream is too.
        oversized?(response, max_body) or byte_size(raw) > max_body ->
          {:error, :body_too_large}

        true ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) ->
              {:ok, %{status: 200, body: decoded, headers: %{"etag" => header(response, "etag")}}}

            _ ->
              {:error, :malformed_body}
          end
      end
    end

    defp oversized?(response, max_body) do
      case header(response, "content-length") do
        nil ->
          false

        value ->
          case Integer.parse(value) do
            {length, _} -> length > max_body
            :error -> false
          end
      end
    end

    defp header(response, name) do
      response
      |> Req.Response.get_header(name)
      |> List.first()
    end
  end
end
