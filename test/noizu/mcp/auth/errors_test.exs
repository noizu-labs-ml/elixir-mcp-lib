defmodule Noizu.MCP.Auth.Server.ErrorsTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Errors
  alias Noizu.MCP.Auth.Server.Params

  doctest Noizu.MCP.Auth.Server.Errors
  doctest Noizu.MCP.Auth.Server.Params

  describe "error_description never reflects input" do
    test "a reason is carried privately and renders nowhere" do
      error = Errors.new(:invalid_request, reason: {:missing, "<script>alert(1)</script>"})

      assert error.reason == {:missing, "<script>alert(1)</script>"}
      refute Errors.to_map(error)["error_description"] =~ "alert"
      refute URI.decode_query(Errors.to_query(error))["error_description"] =~ "alert"
    end

    test "the description is fixed per code, whatever the input was" do
      a = Errors.new(:invalid_grant, reason: :replayed)
      b = Errors.new(:invalid_grant, reason: :expired)

      assert Errors.to_map(a) == Errors.to_map(b)
    end

    test "an unknown code becomes server_error rather than being echoed" do
      assert Errors.new(:not_a_real_code).code == :server_error
      assert Errors.new("../../etc/passwd").code == :server_error
      assert Errors.new(nil).code == :server_error
      assert Errors.new(%{}).code == :server_error
    end

    test "a string code maps without touching the atom table" do
      assert Errors.new("invalid_client").code == :invalid_client
    end
  end

  describe "rendering" do
    test "to_map/1 carries code and description" do
      assert %{"error" => "invalid_client", "error_description" => description} =
               Errors.to_map(:invalid_client)

      assert is_binary(description)
    end

    test "state is echoed only when set" do
      refute Map.has_key?(Errors.to_map(Errors.new(:access_denied)), "state")

      assert Errors.new(:access_denied)
             |> Errors.with_state("xyz")
             |> Errors.to_map()
             |> Map.get("state") ==
               "xyz"
    end

    test "statuses follow the RFCs" do
      assert Errors.status(:invalid_request) == 400
      assert Errors.status(:invalid_client) == 401
      assert Errors.status(:invalid_grant) == 400
      assert Errors.status(:access_denied) == 403
      assert Errors.status(:insufficient_scope) == 403
      assert Errors.status(:server_error) == 500
      assert Errors.status(:temporarily_unavailable) == 503
      assert Errors.status(Errors.new(:invalid_scope, status: 418)) == 418
    end

    test "every code renders" do
      for code <- Errors.codes() do
        assert %{"error" => _, "error_description" => _} = Errors.to_map(code)
        assert is_integer(Errors.status(code))
      end
    end

    test "annotate/2 attaches a reason without changing the rendering" do
      base = Errors.new(:invalid_grant)
      assert Errors.to_map(Errors.annotate(base, :whatever)) == Errors.to_map(base)
    end
  end

  describe "redirect_url/2" do
    test "appends to a URI with no query" do
      url = Errors.redirect_url("https://claude.ai/cb", Errors.new(:access_denied))
      assert url =~ "https://claude.ai/cb?"
      assert URI.decode_query(URI.parse(url).query)["error"] == "access_denied"
    end

    test "preserves an existing query" do
      url =
        Errors.redirect_url(
          "http://127.0.0.1:5000/cb?session=abc",
          Errors.new(:access_denied) |> Errors.with_state("st")
        )

      query = URI.decode_query(URI.parse(url).query)
      assert query["session"] == "abc"
      assert query["state"] == "st"
      assert query["error"] == "access_denied"
    end
  end

  describe "Params" do
    test "fetch/3 requires a present, non-blank single value" do
      assert {:ok, "abc"} = Params.fetch(%{"client_id" => "abc"}, "client_id")
      assert {:error, %Errors{code: :invalid_request}} = Params.fetch(%{}, "client_id")
      assert {:error, %Errors{}} = Params.fetch(%{"client_id" => ""}, "client_id")
    end

    test "a repeated parameter is rejected, not silently resolved" do
      assert {:error, %Errors{code: :invalid_request}} =
               Params.fetch(%{"scope" => ["mcp", "admin"]}, "scope")

      assert {:error, %Errors{}} = Params.fetch(%{"scope" => %{"a" => "b"}}, "scope")
    end

    test "an oversized value is rejected" do
      assert {:error, %Errors{}} =
               Params.fetch(%{"state" => String.duplicate("x", 5_000)}, "state")

      assert {:ok, _} =
               Params.fetch(%{"state" => String.duplicate("x", 5_000)}, "state", max: 8_000)
    end

    test "the error code is overridable per call site" do
      assert {:error, %Errors{code: :invalid_client}} =
               Params.fetch(%{}, "client_id", code: :invalid_client)
    end

    test "optional/3 treats blank as absent" do
      assert {:ok, nil} = Params.optional(%{"state" => ""}, "state")
      assert {:ok, nil} = Params.optional(%{}, "state")
      assert {:ok, "s"} = Params.optional(%{"state" => "s"}, "state")
    end

    test "fetch_all/3 fails on the first missing key" do
      assert {:ok, %{"a" => "1", "b" => "2"}} =
               Params.fetch_all(%{"a" => "1", "b" => "2"}, ["a", "b"])

      assert {:error, %Errors{}} = Params.fetch_all(%{"a" => "1"}, ["a", "b"])
    end

    test "space_list/3 splits, dedupes and preserves order" do
      assert {:ok, ["mcp", "admin"]} =
               Params.space_list(%{"scope" => "mcp  admin mcp"}, "scope")

      assert {:ok, []} = Params.space_list(%{}, "scope")
    end

    test "allowed/3 checks an allowlist without echoing the value" do
      assert :ok = Params.allowed("code", ["code"])
      assert {:error, %Errors{code: :invalid_request}} = Params.allowed("token", ["code"])

      assert {:error, %Errors{code: :unsupported_response_type}} =
               Params.allowed("token", ["code"], code: :unsupported_response_type)
    end

    test "within_scope/2 refuses a scope the client may not have" do
      assert {:ok, ["mcp"]} = Params.within_scope(["mcp"], ["mcp", "mcp:admin"])
      assert {:error, %Errors{code: :invalid_scope}} = Params.within_scope(["root"], ["mcp"])
      assert {:ok, []} = Params.within_scope([], ["mcp"])
    end

    test "basic_credentials/1 decodes RFC 6749 §2.3.1 form" do
      header = "Basic " <> Base.encode64("my%2Bclient:s3%3Acret")
      assert {:ok, {"my+client", "s3:cret"}} = Params.basic_credentials(header)
    end

    test "basic_credentials/1 ignores a non-Basic header" do
      assert {:ok, nil} = Params.basic_credentials(nil)
      assert {:ok, nil} = Params.basic_credentials("Bearer abc")
    end

    test "a malformed Basic header is invalid_client" do
      assert {:error, %Errors{code: :invalid_client}} = Params.basic_credentials("Basic !!!")

      assert {:error, %Errors{code: :invalid_client}} =
               Params.basic_credentials("Basic " <> Base.encode64("no-colon"))
    end
  end
end
