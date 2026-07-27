defmodule Noizu.MCP.Auth.Server.SSRFTest do
  @moduledoc """
  The CIMD fetch dereferences a URL the *client* chose, so this table is the
  guard rail. It is written out address by address on purpose: a range quietly
  dropped from the denylist is invisible in any aggregate assertion.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.SSRF
  alias Noizu.MCP.Fixtures

  doctest Noizu.MCP.Auth.Server.SSRF

  @blocked_v4 [
    {"this network 0.0.0.0/8", {0, 0, 0, 0}},
    {"this network 0.1.2.3", {0, 1, 2, 3}},
    {"private 10/8", {10, 0, 0, 1}},
    {"private 10/8 upper", {10, 255, 255, 254}},
    {"CGNAT 100.64/10 low", {100, 64, 0, 1}},
    {"CGNAT 100.64/10 high", {100, 127, 255, 254}},
    {"loopback 127/8", {127, 0, 0, 1}},
    {"loopback 127/8 other", {127, 1, 2, 3}},
    {"link-local 169.254/16", {169, 254, 0, 1}},
    {"cloud metadata 169.254.169.254", {169, 254, 169, 254}},
    {"private 172.16/12 low", {172, 16, 0, 1}},
    {"private 172.16/12 high", {172, 31, 255, 254}},
    {"protocol assignments 192.0.0/24", {192, 0, 0, 8}},
    {"TEST-NET-1 192.0.2/24", {192, 0, 2, 1}},
    {"6to4 relay 192.88.99/24", {192, 88, 99, 1}},
    {"private 192.168/16", {192, 168, 1, 1}},
    {"benchmarking 198.18/15", {198, 18, 0, 1}},
    {"benchmarking 198.19/16", {198, 19, 0, 1}},
    {"TEST-NET-2 198.51.100/24", {198, 51, 100, 1}},
    {"TEST-NET-3 203.0.113/24", {203, 0, 113, 1}},
    {"multicast 224/4", {224, 0, 0, 1}},
    {"multicast 239/8", {239, 255, 255, 255}},
    {"reserved 240/4", {240, 0, 0, 1}},
    {"broadcast", {255, 255, 255, 255}}
  ]

  @blocked_v6 [
    {"unspecified ::", {0, 0, 0, 0, 0, 0, 0, 0}},
    {"loopback ::1", {0, 0, 0, 0, 0, 0, 0, 1}},
    {"unique-local fc00::/7 low", {0xFC00, 0, 0, 0, 0, 0, 0, 1}},
    {"unique-local fd00::", {0xFD00, 0, 0, 0, 0, 0, 0, 1}},
    {"unique-local fdff::", {0xFDFF, 0, 0, 0, 0, 0, 0, 1}},
    {"link-local fe80::", {0xFE80, 0, 0, 0, 0, 0, 0, 1}},
    {"link-local febf::", {0xFEBF, 0, 0, 0, 0, 0, 0, 1}},
    {"multicast ff02::1", {0xFF02, 0, 0, 0, 0, 0, 0, 1}},
    {"documentation 2001:db8::", {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}},
    {"discard-only 100::", {0x0100, 0, 0, 0, 0, 0, 0, 1}}
  ]

  @blocked_mapped [
    {"v4-mapped metadata ::ffff:169.254.169.254", {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}},
    {"v4-mapped loopback ::ffff:127.0.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}},
    {"v4-mapped private ::ffff:10.0.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}},
    {"v4-mapped private ::ffff:192.168.1.1", {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101}},
    {"v4-compatible ::127.0.0.1", {0, 0, 0, 0, 0, 0, 0x7F00, 0x0001}},
    {"v4-compatible ::169.254.169.254", {0, 0, 0, 0, 0, 0, 0xA9FE, 0xA9FE}},
    {"NAT64 64:ff9b::169.254.169.254", {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE}},
    {"NAT64 64:ff9b::10.0.0.1", {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}}
  ]

  @allowed [
    {"public v4", {93, 184, 216, 34}},
    {"public v4 (1.1.1.1)", {1, 1, 1, 1}},
    {"public v4 (8.8.8.8)", {8, 8, 8, 8}},
    {"just below CGNAT", {100, 63, 255, 255}},
    {"just above CGNAT", {100, 128, 0, 1}},
    {"just below 172.16/12", {172, 15, 255, 255}},
    {"just above 172.16/12", {172, 32, 0, 1}},
    {"just below multicast", {223, 255, 255, 255}},
    {"public v6", {0x2606, 0x2800, 0x0220, 1, 0x248, 0x1893, 0x25C8, 0x1946}},
    {"v4-mapped public ::ffff:93.184.216.34", {0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822}}
  ]

  describe "blocked_ip?/1" do
    for {name, ip} <- @blocked_v4 ++ @blocked_v6 ++ @blocked_mapped do
      test "blocks #{name}" do
        assert SSRF.blocked_ip?(unquote(Macro.escape(ip)))
      end
    end

    for {name, ip} <- @allowed do
      test "allows #{name}" do
        refute SSRF.blocked_ip?(unquote(Macro.escape(ip)))
      end
    end

    test "anything that is not an address is blocked" do
      assert SSRF.blocked_ip?(nil)
      assert SSRF.blocked_ip?("127.0.0.1")
      assert SSRF.blocked_ip?({1, 2, 3})
      assert SSRF.blocked_ip?({999, 1, 1, 1})
      assert SSRF.blocked_ip?({-1, 1, 1, 1})
    end
  end

  describe "check_url/2 scheme and shape" do
    test "https to a public host passes" do
      assert {:ok, %{addresses: [{93, 184, 216, 34}]}} =
               SSRF.check_url("https://public.example.com/.well-known/mcp", Fixtures.OAuth.ssrf_opts())
    end

    test "http is refused" do
      assert {:error, :scheme_not_allowed} =
               SSRF.check_url("http://public.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    for url <- [
          "file:///etc/passwd",
          "gopher://public.example.com/x",
          "ftp://public.example.com/x",
          "data:text/plain,hi"
        ] do
      test "refuses #{url}" do
        assert {:error, :scheme_not_allowed} =
                 SSRF.check_url(unquote(url), Fixtures.OAuth.ssrf_opts())
      end
    end

    test "a non-443 port is refused" do
      assert {:error, :port_not_allowed} =
               SSRF.check_url("https://public.example.com:8443/x", Fixtures.OAuth.ssrf_opts())
    end

    test "userinfo is refused" do
      assert {:error, :userinfo_not_allowed} =
               SSRF.check_url("https://user:pw@public.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    test "a hostless or non-binary URL is refused" do
      assert {:error, :invalid_url} = SSRF.check_url("https:///x", Fixtures.OAuth.ssrf_opts())
      assert {:error, :invalid_url} = SSRF.check_url(nil, Fixtures.OAuth.ssrf_opts())
    end
  end

  describe "check_url/2 address checks" do
    test "a host resolving to the cloud metadata address is refused" do
      assert {:error, :blocked_address} =
               SSRF.check_url("https://metadata.example.com/latest/meta-data/", Fixtures.OAuth.ssrf_opts())
    end

    test "a host resolving to a private address is refused" do
      assert {:error, :blocked_address} =
               SSRF.check_url("https://internal.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    test "a host resolving to a v4-mapped private address is refused" do
      assert {:error, :blocked_address} =
               SSRF.check_url("https://mapped.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    test "one blocked answer among several poisons the whole name" do
      # A split-horizon answer is a rebinding attempt; every address has to be
      # public or the name is unusable.
      assert {:error, :blocked_address} =
               SSRF.check_url("https://split.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    test "an unresolvable host is refused" do
      assert {:error, :unresolvable_host} =
               SSRF.check_url("https://nope.example.com/x", Fixtures.OAuth.ssrf_opts())
    end

    test "an IP literal is checked without DNS" do
      assert {:error, :blocked_address} =
               SSRF.check_url("https://169.254.169.254/latest/", Fixtures.OAuth.ssrf_opts())

      assert {:error, :blocked_address} =
               SSRF.check_url("https://[::ffff:169.254.169.254]/latest/", Fixtures.OAuth.ssrf_opts())

      assert {:error, :blocked_address} =
               SSRF.check_url("https://[::1]/x", Fixtures.OAuth.ssrf_opts())

      assert {:ok, _} = SSRF.check_url("https://93.184.216.34/x", Fixtures.OAuth.ssrf_opts())
    end

    test "a public v6 host passes" do
      assert {:ok, _} = SSRF.check_url("https://v6.example.com/x", Fixtures.OAuth.ssrf_opts())
    end
  end

  describe "fetch limits" do
    test "the fetcher contract pins body, timeout and redirects" do
      opts = SSRF.fetch_opts()

      # Following one redirect is all it takes to reach 169.254.169.254 from a
      # host that passed the address check.
      assert Keyword.fetch!(opts, :redirect) == false
      assert Keyword.fetch!(opts, :max_redirects) == 0
      assert Keyword.fetch!(opts, :max_body) == 64 * 1024
      assert Keyword.fetch!(opts, :timeout) == 5_000
      assert SSRF.max_body() == 65_536
      assert SSRF.timeout() == 5_000
    end
  end
end
