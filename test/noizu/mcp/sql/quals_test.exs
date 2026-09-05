defmodule Noizu.MCP.SQL.QualsTest do
  use ExUnit.Case, async: true

  import ExUnitProperties
  import StreamData

  alias Noizu.MCP.SQL.Quals

  defp err_reason({:error, %{message: message}}), do: message

  describe "decode/2 (FR-9.7)" do
    test "decodes every operator in the vocabulary" do
      quals = [
        %{"column" => "a", "op" => "eq", "value" => 1},
        %{"column" => "b", "op" => "ne", "value" => "x"},
        %{"column" => "c", "op" => "lt", "value" => 2},
        %{"column" => "d", "op" => "lte", "value" => 3},
        %{"column" => "e", "op" => "gt", "value" => 4},
        %{"column" => "f", "op" => "gte", "value" => 5},
        %{"column" => "g", "op" => "in", "value" => [1, 2]},
        %{"column" => "h", "op" => "not_in", "value" => [3]},
        %{"column" => "i", "op" => "like", "value" => "ro%"},
        %{"column" => "j", "op" => "is_null"},
        %{"column" => "k", "op" => "is_not_null"}
      ]

      assert {:ok, decoded} = Quals.decode(quals)

      assert Enum.map(decoded, & &1.op) == [
               :eq,
               :ne,
               :lt,
               :lte,
               :gt,
               :gte,
               :in,
               :not_in,
               :like,
               :is_null,
               :is_not_null
             ]
    end

    test "accepts atom ops too (handler-internal callers)" do
      assert {:ok, [%{op: :eq, value: 1}]} =
               Quals.decode([%{"column" => "a", "op" => :eq, "value" => 1}])
    end

    test "nil decodes to the empty list" do
      assert Quals.decode(nil) == {:ok, []}
    end

    test "unknown operator → invalid_params (FR-9.7)" do
      assert {:error, error} = Quals.decode([%{"column" => "a", "op" => "regex", "value" => "x"}])
      assert error.code == -32602
      assert err_reason({:error, error}) =~ "unknown qual operator"
    end

    test "non-binary op, missing column, non-string column → invalid_params" do
      assert {:error, %{code: -32602}} = Quals.decode([%{"column" => "a", "op" => 7}])
      assert {:error, %{code: -32602}} = Quals.decode([%{"op" => "eq", "value" => 1}])
      assert {:error, %{code: -32602}} = Quals.decode([%{"column" => 3, "op" => "eq"}])
      assert {:error, %{code: -32602}} = Quals.decode(["not-a-map"])
    end

    test "non-list input → invalid_params" do
      assert {:error, %{code: -32602}} = Quals.decode(%{"column" => "a"})
      assert {:error, %{code: -32602}} = Quals.decode(7)
    end

    test "in/not_in require list values" do
      assert {:error, %{code: -32602}} =
               Quals.decode([%{"column" => "a", "op" => "in", "value" => 1}])

      assert {:error, %{code: -32602}} =
               Quals.decode([%{"column" => "a", "op" => "not_in", "value" => "x"}])
    end

    test ":columns restriction rejects quals outside the pushdown set" do
      quals = [%{"column" => "name", "op" => "eq", "value" => "x"}]

      assert {:ok, _} = Quals.decode(quals, columns: ["name"])
      assert {:error, %{code: -32602}} = Quals.decode(quals, columns: ["uri"])
    end

    test "a bad qual anywhere rejects the whole list" do
      quals = [
        %{"column" => "a", "op" => "eq", "value" => 1},
        %{"column" => "b", "op" => "explode"}
      ]

      assert {:error, %{code: -32602}} = Quals.decode(quals)
    end
  end

  describe "apply/2 — the pure reference re-filter" do
    defp rows do
      [
        %{"id" => 1, "name" => "alpha", "score" => 10, "tag" => nil},
        %{"id" => 2, "name" => "beta", "score" => 20, "tag" => "x"},
        %{"id" => 3, "name" => "gamma", "score" => 30, "tag" => "x"},
        %{"id" => 4, "name" => "Alphas", "score" => 20.5, "tag" => "y"}
      ]
    end

    test "eq / ne" do
      assert [%{"id" => 2}] = Quals.apply(rows(), [%{column: "id", op: :eq, value: 2}])

      assert [%{"id" => 1}, %{"id" => 3}, %{"id" => 4}] =
               Quals.apply(rows(), [%{column: "name", op: :ne, value: "beta"}])
    end

    test "ordered comparisons" do
      assert [%{"id" => 1}, %{"id" => 2}] =
               Quals.apply(rows(), [%{column: "score", op: :lte, value: 20}])

      assert [%{"id" => 1}] = Quals.apply(rows(), [%{column: "score", op: :lt, value: 10.5}])

      assert [%{"id" => 3}, %{"id" => 4}] =
               Quals.apply(rows(), [%{column: "score", op: :gt, value: 20}])

      assert [%{"id" => 2}, %{"id" => 3}, %{"id" => 4}] =
               Quals.apply(rows(), [%{column: "score", op: :gte, value: 20}])
    end

    test "numbers compare across integer/float" do
      assert [%{"id" => 4}] = Quals.apply(rows(), [%{column: "score", op: :eq, value: 20.5}])

      assert [%{"id" => 2}, %{"id" => 3}] =
               Quals.apply(rows(), [%{column: "score", op: :in, value: [20, 30]}])
    end

    test "in / not_in" do
      assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}] =
               Quals.apply(rows(), [%{column: "name", op: :in, value: ["alpha", "beta", "gamma"]}])

      assert [%{"id" => 4}] =
               Quals.apply(rows(), [
                 %{column: "name", op: :not_in, value: ["alpha", "beta", "gamma"]}
               ])
    end

    test "like follows SQL wildcards, not regex" do
      assert [%{"id" => 1}] = Quals.apply(rows(), [%{column: "name", op: :like, value: "alp%"}])
      assert [%{"id" => 4}] = Quals.apply(rows(), [%{column: "name", op: :like, value: "_lphas"}])
      assert [%{"id" => 4}] = Quals.apply(rows(), [%{column: "name", op: :like, value: "Alp%"}])
      # A regex metacharacter inside the pattern is literal.
      assert [] = Quals.apply(rows(), [%{column: "name", op: :like, value: "a(lpha"}])
      assert [] = Quals.apply(rows(), [%{column: "score", op: :like, value: "10"}])
    end

    test "is_null / is_not_null" do
      assert [%{"id" => 1}] = Quals.apply(rows(), [%{column: "tag", op: :is_null}])

      assert [%{"id" => 2}, %{"id" => 3}, %{"id" => 4}] =
               Quals.apply(rows(), [%{column: "tag", op: :is_not_null}])
    end

    test "nil is unknown: ordered comparisons against nil are false on both sides" do
      assert [] = Quals.apply(rows(), [%{column: "tag", op: :gt, value: "z"}])
      assert [] = Quals.apply(rows(), [%{column: "tag", op: :lt, value: "a"}])
      assert [] = Quals.apply(rows(), [%{column: "tag", op: :eq, value: nil}])
      assert [] = Quals.apply(rows(), [%{column: "tag", op: :ne, value: nil}])
    end

    test "conjunction of quals" do
      quals = [%{column: "tag", op: :eq, value: "x"}, %{column: "score", op: :gt, value: 25}]
      assert [%{"id" => 3}] = Quals.apply(rows(), quals)
    end

    test "preserves input order and the input list itself (purity)" do
      original = rows()
      quals = [%{column: "score", op: :gte, value: 10}]

      result = Quals.apply(original, quals)

      assert Enum.map(result, & &1["id"]) == Enum.map(original, & &1["id"])
      assert original == rows()
      assert length(result) == 4
    end

    test "satisfies?/2 agrees with apply/2 row-by-row" do
      quals = [%{column: "score", op: :gte, value: 20}, %{column: "tag", op: :eq, value: "x"}]

      for row <- rows() do
        assert Quals.satisfies?(row, quals) == Enum.member?(Quals.apply(rows(), quals), row)
      end
    end

    # Property: apply/2 is exactly "every qual satisfied" — the reference
    # re-check contract the conformance suite leans on (PRD-9 §7).
    property "apply/2 ≡ Enum.filter by satisfies?/2 for arbitrary quals" do
      check all(
              scores <- list_of(integer(), min_length: 1, max_length: 12),
              threshold <- integer(),
              ops <- member_of([:gte, :lte, :eq, :ne])
            ) do
        rows =
          Enum.map(Enum.with_index(scores), fn {score, i} -> %{"id" => i, "score" => score} end)

        quals = [%{column: "score", op: ops, value: threshold}]

        assert Quals.apply(rows, quals) ==
                 Enum.filter(rows, &Quals.satisfies?(&1, quals))
      end
    end
  end

  describe "to_wire/1" do
    test "inverts decode/2" do
      wire = [
        %{"column" => "a", "op" => "eq", "value" => 1},
        %{"column" => "b", "op" => "is_null"}
      ]

      assert {:ok, decoded} = Quals.decode(wire)
      assert Enum.map(decoded, &Quals.to_wire/1) == wire
    end

    test "valueless ops carry no value key" do
      assert {:ok, decoded} = Quals.decode([%{"column" => "b", "op" => "is_null"}])
      refute Map.has_key?(Quals.to_wire(hd(decoded)), "value")
    end
  end
end
