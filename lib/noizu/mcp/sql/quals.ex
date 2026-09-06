defmodule Noizu.MCP.SQL.Quals do
  @moduledoc """
  Wire-qual decoding and a pure reference filter (PRD-9 §4.4).

  A qual is one pushed-down predicate: `%{column: name, op: operator, value:
  term}`. `decode/2` parses the wire list into that shape, rejecting unknown
  operators with `invalid_params`; `apply/2` is a pure, side-effect-free
  re-filter over map rows.

  ## The re-check contract (normative)

  Quals are a hint. The client re-checks every one of them locally, so a
  dataset MAY ignore any qual it does not want to implement — the honest
  minimum `scan/3` ignores `opts` entirely and returns every row. What a
  dataset must never do is return a row that a qual it *did* apply would have
  excluded, or drop a row that a qual it did not apply would have kept.

  `scan/3` deliberately does not report which quals it applied. Because the
  caller re-checks unconditionally, the contract stays one-directional and a
  whole class of "the server said it filtered but did not" bug disappears.

  `apply/2` is the reference implementation of that re-check; the conformance
  suite uses it to prove a dataset's own filtering agrees with it.
  """

  import Kernel, except: [apply: 2, match?: 2]

  alias Noizu.MCP.Error

  @operators [:eq, :ne, :lt, :lte, :gt, :gte, :in, :not_in, :like, :is_null, :is_not_null]
  @valueless [:is_null, :is_not_null]
  @list_valued [:in, :not_in]

  @type op ::
          :eq | :ne | :lt | :lte | :gt | :gte | :in | :not_in | :like | :is_null | :is_not_null

  @type t :: %{column: String.t(), op: op(), value: term()}

  @type row :: %{String.t() => term()}

  @doc "The closed operator vocabulary, in wire order."
  @spec operators() :: [op()]
  def operators, do: @operators

  @doc """
  Decode a wire qual list into `[t()]`.

  Each entry is `%{"column" => string, "op" => string, "value" => term}`;
  `"value"` is omitted for `is_null`/`is_not_null` and must be a list for
  `in`/`not_in`. Options:

    * `:columns` — when given, a qual naming a column outside the list is
      rejected with `invalid_params`.

  Returns `{:ok, quals}` or `{:error, %Noizu.MCP.Error{reason: :invalid_params}}`.
  """
  @spec decode(term(), keyword()) :: {:ok, [t()]} | {:error, Error.t()}
  def decode(quals, opts \\ [])

  def decode(nil, _opts), do: {:ok, []}

  def decode(quals, opts) when is_list(quals) do
    columns = Keyword.get(opts, :columns)

    Enum.reduce_while(quals, {:ok, []}, fn qual, {:ok, acc} ->
      case decode_one(qual, columns) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, %Error{}} = error -> error
    end
  end

  def decode(other, _opts),
    do: {:error, Error.invalid_params("quals must be a list, got: #{inspect(other)}")}

  defp decode_one(%{"column" => column, "op" => op} = qual, columns) when is_binary(column) do
    with {:ok, op} <- decode_op(op),
         :ok <- check_column(column, columns),
         {:ok, value} <- decode_value(op, qual) do
      {:ok, %{column: column, op: op, value: value}}
    end
  end

  defp decode_one(other, _columns),
    do:
      {:error,
       Error.invalid_params(
         "each qual requires a string \"column\" and an \"op\", got: #{inspect(other)}"
       )}

  # String.to_existing_atom would still mint nothing useful for a bad operator;
  # matching the closed list keeps the vocabulary explicit and the error honest.
  defp decode_op(op) when is_binary(op) do
    case Enum.find(@operators, fn known -> Atom.to_string(known) == op end) do
      nil -> {:error, unknown_operator(op)}
      known -> {:ok, known}
    end
  end

  defp decode_op(op) when op in @operators, do: {:ok, op}
  defp decode_op(op), do: {:error, unknown_operator(inspect(op))}

  defp unknown_operator(op) do
    Error.invalid_params(
      "unknown qual operator #{inspect(op)} — expected one of " <>
        Enum.map_join(@operators, ", ", &Atom.to_string/1)
    )
  end

  defp check_column(_column, nil), do: :ok

  defp check_column(column, columns) when is_list(columns) do
    if column in columns do
      :ok
    else
      {:error,
       Error.invalid_params(
         "unknown qual column #{inspect(column)} — expected one of #{inspect(columns)}"
       )}
    end
  end

  defp decode_value(op, _qual) when op in @valueless, do: {:ok, nil}

  defp decode_value(op, qual) when op in @list_valued do
    case Map.get(qual, "value") do
      value when is_list(value) ->
        {:ok, value}

      other ->
        {:error,
         Error.invalid_params("qual operator #{op} requires a list value, got: #{inspect(other)}")}
    end
  end

  defp decode_value(_op, qual), do: {:ok, Map.get(qual, "value")}

  @doc "Render a decoded qual back to its wire map (the inverse of `decode/2`)."
  @spec to_wire(t()) :: map()
  def to_wire(%{column: column, op: op} = qual) do
    %{"column" => column, "op" => Atom.to_string(op)}
    |> then(fn map ->
      if op in @valueless, do: map, else: Map.put(map, "value", Map.get(qual, :value))
    end)
  end

  @doc """
  Filter `rows` (maps keyed by column name) by `quals`. Pure: no process
  state, no I/O, and the result preserves input order.

  A column absent from a row reads as `nil`. Ordered comparisons against `nil`
  on either side are false — `nil` is unknown, not smallest.
  """
  @spec apply([row()], [t()]) :: [row()]
  def apply(rows, quals) when is_list(rows) and is_list(quals) do
    Enum.filter(rows, fn row -> satisfies?(row, quals) end)
  end

  @doc "True when `row` satisfies every qual in `quals`."
  @spec satisfies?(row(), [t()]) :: boolean()
  def satisfies?(row, quals) when is_map(row) and is_list(quals) do
    Enum.all?(quals, fn qual -> match?(row, qual) end)
  end

  @doc "True when `row` satisfies one qual."
  @spec match?(row(), t()) :: boolean()
  def match?(row, %{column: column, op: op} = qual) do
    evaluate(op, Map.get(row, column), Map.get(qual, :value))
  end

  defp evaluate(:is_null, actual, _value), do: is_nil(actual)
  defp evaluate(:is_not_null, actual, _value), do: not is_nil(actual)

  # SQL three-valued logic: `x = NULL` and `x <> NULL` are unknown, never
  # true — only is_null/is_not_null reason about absence.
  defp evaluate(_op, nil, _value), do: false
  defp evaluate(_op, _actual, nil), do: false

  defp evaluate(:eq, actual, value), do: equal?(actual, value)
  defp evaluate(:ne, actual, value), do: not equal?(actual, value)

  defp evaluate(:in, actual, values) when is_list(values),
    do: Enum.any?(values, &equal?(actual, &1))

  defp evaluate(:in, _actual, _values), do: false

  defp evaluate(:not_in, actual, values) when is_list(values),
    do: not Enum.any?(values, &equal?(actual, &1))

  defp evaluate(:not_in, _actual, _values), do: true

  defp evaluate(:like, actual, pattern) when is_binary(actual) and is_binary(pattern),
    do: Regex.match?(like_regex(pattern), actual)

  defp evaluate(:like, _actual, _pattern), do: false

  defp evaluate(:lt, actual, value), do: compare(actual, value) == :lt
  defp evaluate(:lte, actual, value), do: compare(actual, value) in [:lt, :eq]
  defp evaluate(:gt, actual, value), do: compare(actual, value) == :gt
  defp evaluate(:gte, actual, value), do: compare(actual, value) in [:gt, :eq]

  # Numbers compare numerically across integer/float; everything else uses
  # Erlang term order, which is total and therefore never raises.
  defp compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp compare(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp equal?(a, b), do: a === b

  # SQL LIKE: `%` is any run, `_` is one character; everything else is literal.
  defp like_regex(pattern) do
    source =
      pattern
      |> String.graphemes()
      |> Enum.map_join(fn
        "%" -> ".*"
        "_" -> "."
        char -> Regex.escape(char)
      end)

    Regex.compile!("\\A" <> source <> "\\z", "su")
  end
end
