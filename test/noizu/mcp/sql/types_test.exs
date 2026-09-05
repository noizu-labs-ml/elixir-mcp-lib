defmodule Noizu.MCP.SQL.TypesTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.SQL.Types

  # ── AC-9.8: the shared fixture table ──────────────────────────────────────
  #
  # PRD-8 §4.1's Rust-side JSON Schema → Postgres map. The two trees assert
  # against the same table so a dataset column and a generated tool column of
  # the same logical type can never disagree.

  @shared_fixture_table [
    {:text, "text"},
    {:bigint, "bigint"},
    {:double, "double precision"},
    {:boolean, "boolean"},
    {:timestamptz, "timestamptz"},
    {:date, "date"},
    {:uuid, "uuid"},
    {:jsonb, "jsonb"},
    # PRD-8: enum renders as text; permitted values travel separately.
    {{:enum, ["plain", "loud"]}, "text"}
  ]

  describe "to_sql/1 vs the PRD-8 §4.1 shared fixture table (AC-9.8)" do
    test "every member of the vocabulary renders exactly the PRD-8 type" do
      for {type, pg} <- @shared_fixture_table do
        assert Types.to_sql(type) == pg, "#{inspect(type)} should render as #{pg}"
      end
    end

    test "vocabulary/0 covers every non-parameterized member" do
      assert Types.vocabulary() == [
               :text,
               :bigint,
               :double,
               :boolean,
               :timestamptz,
               :date,
               :uuid,
               :jsonb
             ]

      for type <- Types.vocabulary() do
        assert Types.valid?(type)
      end
    end

    test "valid?/1 accepts {:enum, [strings]} and nothing else" do
      assert Types.valid?({:enum, ["a"]})
      refute Types.valid?({:enum, []})
      refute Types.valid?({:enum, [1]})
      refute Types.valid?({:array, :text})
      refute Types.valid?(:integer)
      refute Types.valid?("text")
    end

    test "to_sql/1 raises on non-members" do
      assert_raise ArgumentError, ~r/not a Noizu.MCP.SQL.Types member/, fn ->
        Types.to_sql(:integer)
      end
    end
  end

  describe "wire round-trip" do
    test "to_wire/1 emits the SQL name plus enum members" do
      assert Types.to_wire(:timestamptz) == %{"type" => "timestamptz"}
      assert Types.to_wire({:enum, ["a", "b"]}) == %{"type" => "text", "enum" => ["a", "b"]}
    end

    test "from_wire/1 inverts to_wire/1 across the vocabulary" do
      for type <- Types.vocabulary() do
        assert type |> Types.to_wire() |> Types.from_wire() == type
      end

      assert {:enum, ["a", "b"]} =
               {:enum, ["a", "b"]} |> Types.to_wire() |> Types.from_wire()
    end

    test "from_wire/1 maps unknown names to :jsonb, losslessly" do
      assert Types.from_wire(%{"type" => "interval"}) == :jsonb
      assert Types.from_wire(%{}) == :jsonb
      assert Types.from_wire("text") == :jsonb
    end
  end

  describe "from_field_type/2 over the tool field DSL (PRD-9 §4.3)" do
    # Mirrors lib/noizu/mcp/server/tool/fields.ex:16 scalars, :133 arrays and
    # :150-163 enum/object/array handling.
    test "scalars" do
      assert Types.from_field_type(:string, []) == :text
      assert Types.from_field_type(:integer, []) == :bigint
      assert Types.from_field_type(:number, []) == :double
      assert Types.from_field_type(:boolean, []) == :boolean
    end

    test ":format refines :string" do
      assert Types.from_field_type(:string, format: "date-time") == :timestamptz
      assert Types.from_field_type(:string, format: :"date-time") == :timestamptz
      assert Types.from_field_type(:string, format: "date") == :date
      assert Types.from_field_type(:string, format: :date) == :date
      assert Types.from_field_type(:string, format: "uuid") == :uuid
      assert Types.from_field_type(:string, format: :uuid) == :uuid
      assert Types.from_field_type(:string, format: "email") == :text
    end

    test "objects and arrays are :jsonb, of any inner type" do
      assert Types.from_field_type(:object, []) == :jsonb
      assert Types.from_field_type({:array, :string}, []) == :jsonb
      assert Types.from_field_type({:array, :object}, []) == :jsonb
      assert Types.from_field_type({:array, {:array, :integer}}, []) == :jsonb
    end

    test ":enum with values, else :text" do
      assert Types.from_field_type(:enum, values: [:plain, :loud]) == {:enum, ["plain", "loud"]}
      assert Types.from_field_type(:enum, values: ["a"]) == {:enum, ["a"]}
      assert Types.from_field_type(:enum, []) == :text
      assert Types.from_field_type(:enum, values: []) == :text
    end

    test "unknown DSL types fall back to :jsonb" do
      assert Types.from_field_type(:weird, []) == :jsonb
    end
  end

  describe "from_json_schema/1 (runtime mirror)" do
    test "the PRD-8 JSON Schema map" do
      assert Types.from_json_schema(%{"type" => "string"}) == :text

      assert Types.from_json_schema(%{"type" => "string", "format" => "date-time"}) ==
               :timestamptz

      assert Types.from_json_schema(%{"type" => "string", "format" => "date"}) == :date
      assert Types.from_json_schema(%{"type" => "string", "format" => "uuid"}) == :uuid
      assert Types.from_json_schema(%{"type" => "integer"}) == :bigint
      assert Types.from_json_schema(%{"type" => "number"}) == :double
      assert Types.from_json_schema(%{"type" => "boolean"}) == :boolean
      assert Types.from_json_schema(%{"type" => "object"}) == :jsonb
      assert Types.from_json_schema(%{"type" => "array"}) == :jsonb
    end

    test "string enums become {:enum, _}" do
      assert Types.from_json_schema(%{"type" => "string", "enum" => ["x", "y"]}) ==
               {:enum, ["x", "y"]}
    end

    test "nullable unions resolve to the single non-null branch" do
      assert Types.from_json_schema(%{"type" => ["integer", "null"]}) == :bigint
      # Two non-null branches: jsonb, not a guess.
      assert Types.from_json_schema(%{"type" => ["integer", "boolean"]}) == :jsonb
    end

    test "unknown shapes are :jsonb" do
      assert Types.from_json_schema(%{"$ref" => "#/x"}) == :jsonb
      assert Types.from_json_schema(%{"oneOf" => []}) == :jsonb
      assert Types.from_json_schema(%{}) == :jsonb
      assert Types.from_json_schema(nil) == :jsonb
    end
  end
end
