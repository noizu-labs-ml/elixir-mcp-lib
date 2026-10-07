defmodule Noizu.MCP.Fixtures.BasicValidator do
  @moduledoc false
  # Lives in test/support (compiled with the test env) rather than at the
  # bottom of basic_verifier_test.exs — a same-file module raced the parallel
  # test-file load on CI and intermittently raised UndefinedFunctionError.
  def check("svc", "tok"), do: {:ok, %{scopes: [], claims: %{"sub" => "svc"}}}
  def check(_u, _p), do: :error
end
