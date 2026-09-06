defmodule Noizu.MCP.SQL.Types do
  @moduledoc """
  The closed column-type vocabulary shared by the `sql/*` methods and the
  PostgreSQL foreign-data wrapper (PRD-9 §4.3).

  The vocabulary is deliberately exactly what the FDW's JSON Schema → Postgres
  map can express, so a hand-written dataset column and a column generated from
  a tool's `inputSchema` of the same logical type always land on the same
  PostgreSQL type:

      :text | :bigint | :double | :boolean | :timestamptz | :date | :uuid
      | :jsonb | {:enum, [String.t()]}

  `to_sql/1` renders each member to its PostgreSQL type name — this is the
  single point of agreement between the Elixir and Rust sides. `{:enum, values}`
  renders as `text`: no PostgreSQL enum type is created, because a server may
  change its enum between refreshes and a PG enum cannot shrink.

  Two front ends produce vocabulary members:

    * `from_field_type/2` — the tool field DSL's types
      (`Noizu.MCP.Server.Tool.Fields`), for servers describing columns with
      the same vocabulary they describe tool arguments with;
    * `from_json_schema/1` — a JSON Schema property map, for columns derived
      from a tool's `inputSchema`/`outputSchema` at runtime.

  Anything unrecognized maps to `:jsonb`, which round-trips losslessly.
  """

  @scalars [:text, :bigint, :double, :boolean, :timestamptz, :date, :uuid, :jsonb]

  @type t ::
          :text
          | :bigint
          | :double
          | :boolean
          | :timestamptz
          | :date
          | :uuid
          | :jsonb
          | {:enum, [String.t()]}

  @doc """
  The non-parameterized members of the vocabulary, in declaration order.
  `{:enum, values}` is parameterized and therefore not enumerable here.
  """
  @spec vocabulary() :: [t()]
  def vocabulary, do: @scalars

  @doc "True when `type` is a member of the vocabulary."
  @spec valid?(term()) :: boolean()
  def valid?(type) when type in @scalars, do: true

  def valid?({:enum, values}) when is_list(values) and values != [],
    do: Enum.all?(values, &is_binary/1)

  def valid?(_type), do: false

  @doc """
  The PostgreSQL type name for a vocabulary member. `{:enum, _}` renders as
  `"text"`; the permitted values travel separately (see `to_wire/1`).
  """
  @spec to_sql(t()) :: String.t()
  def to_sql(:text), do: "text"
  def to_sql(:bigint), do: "bigint"
  def to_sql(:double), do: "double precision"
  def to_sql(:boolean), do: "boolean"
  def to_sql(:timestamptz), do: "timestamptz"
  def to_sql(:date), do: "date"
  def to_sql(:uuid), do: "uuid"
  def to_sql(:jsonb), do: "jsonb"
  def to_sql({:enum, values}) when is_list(values), do: "text"

  def to_sql(other) do
    raise ArgumentError,
          "#{inspect(other)} is not a Noizu.MCP.SQL.Types member — " <>
            "expected one of #{inspect(@scalars)} or {:enum, [String.t()]}"
  end

  @doc """
  Render a vocabulary member into its wire fragment: `%{"type" => sql_name}`,
  plus `"enum"` for `{:enum, values}` so a client can document the permitted
  values without inventing a PostgreSQL enum type.
  """
  @spec to_wire(t()) :: map()
  def to_wire({:enum, values}) when is_list(values),
    do: %{"type" => "text", "enum" => Enum.map(values, &to_string/1)}

  def to_wire(type), do: %{"type" => to_sql(type)}

  @doc """
  Parse a wire type fragment back into a vocabulary member. Unknown type names
  decode to `:jsonb` — a client that learns a type this version does not know
  still gets a lossless column.
  """
  @spec from_wire(map()) :: t()
  def from_wire(%{"type" => "text", "enum" => values}) when is_list(values) and values != [],
    do: {:enum, Enum.map(values, &to_string/1)}

  def from_wire(%{"type" => name}) when is_binary(name) do
    Enum.find(@scalars, :jsonb, fn type -> to_sql(type) == name end)
  end

  def from_wire(_other), do: :jsonb

  @doc """
  Map a tool field DSL type onto the vocabulary (PRD-9 §4.3).

  `opts` is the field's option list: `:format` refines `:string`
  (`"date-time"` → `:timestamptz`, `"date"` → `:date`, `"uuid"` → `:uuid`) and
  `:values` supplies an `:enum` field's members. Objects and arrays — of any
  inner type — are `:jsonb`, matching the FDW's deliberate refusal to map JSON
  arrays onto PostgreSQL arrays.
  """
  @spec from_field_type(atom() | {:array, atom()}, keyword()) :: t()
  def from_field_type(type, opts \\ [])

  def from_field_type(:string, opts) do
    case opts[:format] do
      "date-time" -> :timestamptz
      :"date-time" -> :timestamptz
      "date" -> :date
      :date -> :date
      "uuid" -> :uuid
      :uuid -> :uuid
      _other -> :text
    end
  end

  def from_field_type(:integer, _opts), do: :bigint
  def from_field_type(:number, _opts), do: :double
  def from_field_type(:boolean, _opts), do: :boolean
  def from_field_type(:object, _opts), do: :jsonb
  def from_field_type({:array, _inner}, _opts), do: :jsonb

  def from_field_type(:enum, opts) do
    case opts[:values] do
      values when is_list(values) and values != [] -> {:enum, Enum.map(values, &to_string/1)}
      _other -> :text
    end
  end

  def from_field_type(_other, _opts), do: :jsonb

  @doc """
  Map a JSON Schema property map onto the vocabulary — the runtime mirror of
  `from_field_type/2`, used for columns derived from a tool's live
  `inputSchema`/`outputSchema`.

  A union `"type"` list resolves to its single non-`"null"` branch when there
  is exactly one, else `:jsonb`. `$ref`, `oneOf`, `anyOf`, `allOf` and an
  absent `"type"` are all `:jsonb`.
  """
  @spec from_json_schema(term()) :: t()
  def from_json_schema(%{"type" => "string"} = schema) do
    case schema["enum"] do
      values when is_list(values) and values != [] -> {:enum, Enum.map(values, &to_string/1)}
      _other -> from_field_type(:string, format: schema["format"])
    end
  end

  def from_json_schema(%{"type" => "integer"}), do: :bigint
  def from_json_schema(%{"type" => "number"}), do: :double
  def from_json_schema(%{"type" => "boolean"}), do: :boolean
  def from_json_schema(%{"type" => "object"}), do: :jsonb
  def from_json_schema(%{"type" => "array"}), do: :jsonb

  def from_json_schema(%{"type" => types} = schema) when is_list(types) do
    case Enum.reject(types, &(&1 == "null")) do
      [single] -> from_json_schema(Map.put(schema, "type", single))
      _other -> :jsonb
    end
  end

  def from_json_schema(_other), do: :jsonb
end
