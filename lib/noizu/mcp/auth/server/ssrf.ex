defmodule Noizu.MCP.Auth.Server.SSRF do
  @moduledoc """
  Guards for the one place the authorization server fetches a URL a *client*
  chose: the CIMD (client-id metadata document) fetch, where `client_id` is
  itself an `https` URL the server dereferences.

  That is a textbook SSRF primitive, so the fetch is fenced on every side:

    * **https only** — no `http`, no `file`, no `gopher`
    * **no credentials or non-standard ports** in the URL
    * **every resolved address must be public** — the denylist below covers
      IPv4, IPv6, and IPv4-mapped/compatible IPv6, so `[::ffff:169.254.169.254]`
      is refused as firmly as `169.254.169.254`. The cloud metadata endpoint is
      the specific address this exists to stop.
    * **redirects are not followed** — a public URL that 302s to
      `http://169.254.169.254/` would otherwise walk straight through the check
    * **64 KiB body cap** and a **5 s timeout** — a metadata document is a few
      hundred bytes; anything else is a decompression bomb or a slow-loris

  ## Residual risk, stated plainly

  This is a check-then-connect design, so DNS rebinding between
  `check_url/2` and the socket open is **not** eliminated. Closing it fully
  requires connecting to the already-resolved IP while sending the original SNI
  and Host, which neither Req nor Finch exposes cleanly. Accepted, and the
  reason `resolve/2` returns the addresses it checked: a fetcher that *can* pin
  should.

      iex> Noizu.MCP.Auth.Server.SSRF.blocked_ip?({169, 254, 169, 254})
      true
      iex> Noizu.MCP.Auth.Server.SSRF.blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      true
      iex> Noizu.MCP.Auth.Server.SSRF.blocked_ip?({93, 184, 216, 34})
      false
  """

  @max_body 64 * 1024
  @timeout 5_000
  @allowed_ports [443]

  @type ip :: :inet.ip_address()
  @type error ::
          :invalid_url
          | :scheme_not_allowed
          | :port_not_allowed
          | :userinfo_not_allowed
          | :unresolvable_host
          | :blocked_address

  @doc "Maximum CIMD response body, in bytes."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "Fetch timeout, in milliseconds."
  @spec timeout() :: pos_integer()
  def timeout, do: @timeout

  @doc """
  Options a fetcher must honour. Passed to `Noizu.MCP.Auth.Server.CIMD`'s
  `:fetcher` so the transport choice does not get to reinvent the limits.
  """
  @spec fetch_opts() :: keyword()
  def fetch_opts,
    do: [max_body: @max_body, timeout: @timeout, redirect: false, max_redirects: 0]

  @doc """
  Validate a URL for fetching, resolving its host and checking every address.

  Returns `{:ok, %{uri: URI.t(), addresses: [ip]}}`.

  Options:

    * `:resolver` — `fun(host) :: {:ok, [ip]} | {:error, term()}`, so this is
      testable without DNS. Default resolves both A and AAAA records.
    * `:allowed_ports` — default `#{inspect(@allowed_ports)}`.
    * `:allow_private` — **testing only**; skips the address denylist.
  """
  @spec check_url(term(), keyword()) ::
          {:ok, %{uri: URI.t(), addresses: [ip()]}} | {:error, error()}
  def check_url(url, opts \\ [])

  def check_url(url, opts) when is_binary(url) do
    uri = URI.parse(url)
    scheme = uri.scheme && String.downcase(uri.scheme)

    cond do
      scheme != "https" ->
        {:error, :scheme_not_allowed}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :invalid_url}

      not is_nil(uri.userinfo) ->
        {:error, :userinfo_not_allowed}

      uri.port not in Keyword.get(opts, :allowed_ports, @allowed_ports) ->
        {:error, :port_not_allowed}

      true ->
        check_host(uri, opts)
    end
  end

  def check_url(_url, _opts), do: {:error, :invalid_url}

  @doc """
  Resolve a host to every address it answers with (A and AAAA), or an IP
  literal to itself.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, [ip()]} | {:error, :unresolvable_host}
  def resolve(host, opts \\ []) do
    case parse_ip(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      :error ->
        case Keyword.get(opts, :resolver, &default_resolver/1).(host) do
          {:ok, []} -> {:error, :unresolvable_host}
          {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
          _ -> {:error, :unresolvable_host}
        end
    end
  end

  @doc """
  True when an address is in a range that must never be fetched: private,
  loopback, link-local (including `169.254.169.254`), CGNAT, multicast,
  reserved, or the IPv6 spellings of any of those.
  """
  @spec blocked_ip?(term()) :: boolean()
  def blocked_ip?({a, b, c, d})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    # An out-of-range octet is not an address at all — fail closed.
    Enum.any?([a, b, c, d], &(&1 < 0 or &1 > 255)) or blocked_v4?(a, b, c, d)
  end

  def blocked_ip?({_, _, _, _, _, _, _, _} = ip), do: blocked_v6?(ip)
  def blocked_ip?(_ip), do: true

  # ── IPv4 ─────────────────────────────────────────────────────────────────

  # 0.0.0.0/8 "this network" — also how 0.0.0.0 reaches localhost on Linux
  defp blocked_v4?(0, _, _, _), do: true
  # 10.0.0.0/8 private
  defp blocked_v4?(10, _, _, _), do: true
  # 100.64.0.0/10 CGNAT
  defp blocked_v4?(100, b, _, _) when b >= 64 and b <= 127, do: true
  # 127.0.0.0/8 loopback
  defp blocked_v4?(127, _, _, _), do: true
  # 169.254.0.0/16 link-local — includes 169.254.169.254 (cloud metadata)
  defp blocked_v4?(169, 254, _, _), do: true
  # 172.16.0.0/12 private
  defp blocked_v4?(172, b, _, _) when b >= 16 and b <= 31, do: true
  # 192.0.0.0/24 IETF protocol assignments, 192.0.2.0/24 TEST-NET-1
  defp blocked_v4?(192, 0, c, _) when c in [0, 2], do: true
  # 192.88.99.0/24 6to4 relay anycast
  defp blocked_v4?(192, 88, 99, _), do: true
  # 192.168.0.0/16 private
  defp blocked_v4?(192, 168, _, _), do: true
  # 198.18.0.0/15 benchmarking
  defp blocked_v4?(198, b, _, _) when b in [18, 19], do: true
  # 198.51.100.0/24 TEST-NET-2
  defp blocked_v4?(198, 51, 100, _), do: true
  # 203.0.113.0/24 TEST-NET-3
  defp blocked_v4?(203, 0, 113, _), do: true
  # 224.0.0.0/4 multicast, 240.0.0.0/4 reserved, 255.255.255.255 broadcast
  defp blocked_v4?(a, _, _, _) when a >= 224, do: true
  defp blocked_v4?(_, _, _, _), do: false

  # ── IPv6 ─────────────────────────────────────────────────────────────────

  # ::ffff:0:0/96 IPv4-mapped — check the embedded v4 address, or the whole
  # denylist above is bypassed by spelling the target differently.
  defp blocked_v6?({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: blocked_ip?(embedded_v4(g, h))
  # ::/96 IPv4-compatible (deprecated but still routed by some stacks), which
  # also covers :: (unspecified) and ::1 (loopback).
  defp blocked_v6?({0, 0, 0, 0, 0, 0, g, h}), do: blocked_ip?(embedded_v4(g, h))
  # 64:ff9b::/96 NAT64 — translates to an arbitrary v4 target
  defp blocked_v6?({0x64, 0xFF9B, _, _, _, _, g, h}), do: blocked_ip?(embedded_v4(g, h))
  # fc00::/7 unique-local, fe80::/10 link-local, ff00::/8 multicast
  defp blocked_v6?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp blocked_v6?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp blocked_v6?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: true
  # 2001:db8::/32 documentation, 100::/64 discard-only
  defp blocked_v6?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  defp blocked_v6?({0x0100, 0, 0, 0, _, _, _, _}), do: true
  defp blocked_v6?(_ip), do: false

  defp embedded_v4(g, h), do: {div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)}

  # ── internals ────────────────────────────────────────────────────────────

  defp check_host(uri, opts) do
    with {:ok, addresses} <- resolve(uri.host, opts) do
      if Keyword.get(opts, :allow_private, false) or Enum.all?(addresses, &(not blocked_ip?(&1))) do
        {:ok, %{uri: uri, addresses: addresses}}
      else
        {:error, :blocked_address}
      end
    end
  end

  defp parse_ip(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp default_resolver(host) do
    charlist = String.to_charlist(host)

    v4 = getaddrs(charlist, :inet)
    v6 = getaddrs(charlist, :inet6)

    case v4 ++ v6 do
      [] -> {:error, :unresolvable_host}
      addresses -> {:ok, Enum.uniq(addresses)}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family, @timeout) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end
end
