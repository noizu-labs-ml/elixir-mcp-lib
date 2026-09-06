defmodule Noizu.MCP.Server.Features.SQL do
  @moduledoc """
  Feature plumbing for the experimental `sql/*` method family (PRD-9 §4.5).

  Three methods, dispatched through the ordinary session seam so they work
  over every transport:

  | Method | Params | Result |
  |---|---|---|
  | `sql/schema` | `{}` | the `Noizu.MCP.SQL.Schema` payload |
  | `sql/scan` | `relation`, `quals`, `columns`, `sort`, `limit`, `cursor` | `columns`, `rows`, `nextCursor` |
  | `sql/modify` | `relation`, `op`, `rows` / `quals` / `changes` | `rows` for insert and update, `count` for delete |

  Rows travel **positionally** against the returned `columns` array — one
  array per row, not one object. For a wide scan that removes most of the JSON
  payload, and this is the hot path of every foreign-table scan. Handlers and
  datasets still work in maps keyed by column name; the positional conversion
  happens here, filling `nil` for any column a handler omitted.

  A server opts in by registering at least one dataset or by passing
  `sql: true` to `use Noizu.MCP.Server`. Servers that do not opt in never gain
  the `handle_sql_*` callbacks, so the session answers `method_not_found` for
  all three methods and their capabilities carry no `experimental.sql`.
  """

  alias Noizu.MCP.{Ctx, Error}
  alias Noizu.MCP.ACL.{Provider, Resource}
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.SQL.{Quals, Schema}
  alias Noizu.MCP.Server.Features
  alias Noizu.MCP.Types.{Content, ToolResult}

  @default_limit 500
  @max_limit 10_000

  # ── sql/schema ────────────────────────────────────────────────────────────

  @doc "`sql/schema` entry point: delegates to the server's `handle_sql_schema/2`."
  @spec schema(module(), map() | nil, Ctx.t()) :: {:ok, map()} | {:error, Error.t()}
  def schema(server, params, ctx) do
    case server.handle_sql_schema(params || %{}, ctx) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, %Error{}} = error -> error
      other -> {:error, invalid_return("sql/schema", other)}
    end
  end

  @doc "Default `handle_sql_schema`: the derived schema for this server and principal."
  @spec default_schema(module(), map(), Ctx.t()) :: {:ok, map()}
  def default_schema(server, _params, ctx), do: Schema.build(server, ctx, [])

  # ── sql/scan ──────────────────────────────────────────────────────────────

  @doc """
  `sql/scan` entry point: parse the request, delegate to the server's
  `handle_sql_scan/3`, and render map rows positionally.

  `handle_sql_scan/3` returns `{:ok, columns, rows, next_cursor}` — `columns`
  is the output column order, `rows` are maps keyed by column name.
  """
  @spec scan(module(), map() | nil, Ctx.t()) :: {:ok, map()} | {:error, Error.t()}
  def scan(server, params, ctx) do
    params = params || %{}

    with {:ok, relation} <- fetch_relation_param(params, "sql/scan"),
         {:ok, opts} <- scan_opts(params) do
      case server.handle_sql_scan(relation, opts, ctx) do
        {:ok, columns, rows, next_cursor} when is_list(columns) and is_list(rows) ->
          {:ok, render_rows(columns, rows, next_cursor)}

        {:error, %Error{}} = error ->
          error

        other ->
          {:error, invalid_return("sql/scan", other)}
      end
    end
  end

  @doc """
  Default `handle_sql_scan`: resolve the relation, authorize it, honor its
  declared required quals, and read it from whichever source its invoke kind
  names.
  """
  @spec default_scan(module(), String.t(), map(), Ctx.t()) ::
          {:ok, [String.t()], [map()], String.t() | nil} | {:error, Error.t()}
  def default_scan(server, relation, opts, ctx) do
    with {:ok, descriptor} <- Schema.fetch(server, ctx, relation),
         {:ok, quals} <- decode_quals(descriptor, opts),
         :ok <- check_required_quals(descriptor, quals),
         :ok <- authorize(server, descriptor, ctx) do
      columns = output_columns(descriptor, opts)

      case read(server, descriptor, quals, opts, ctx) do
        {:ok, rows, next_cursor} -> {:ok, columns, rows, next_cursor}
        {:error, %Error{}} = error -> error
      end
    end
  end

  # ── sql/modify ────────────────────────────────────────────────────────────

  @doc "`sql/modify` entry point: delegates to the server's `handle_sql_modify/3`."
  @spec modify(module(), map() | nil, Ctx.t()) :: {:ok, map()} | {:error, Error.t()}
  def modify(server, params, ctx) do
    params = params || %{}

    with {:ok, relation} <- fetch_relation_param(params, "sql/modify"),
         {:ok, op} <- fetch_op(params) do
      case server.handle_sql_modify(relation, Map.put(params, "op", Atom.to_string(op)), ctx) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, %Error{}} = error -> error
        other -> {:error, invalid_return("sql/modify", other)}
      end
    end
  end

  @doc """
  Default `handle_sql_modify`: route `insert`/`update`/`delete` to the
  dataset's optional callbacks, or to `tools/call` for a tool-derived relation.

  An op whose callback the dataset does not implement answers
  `method_not_found`, naming both the relation and the op (FR-9.10).
  """
  @spec default_modify(module(), String.t(), map(), Ctx.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def default_modify(server, relation, params, ctx) do
    with {:ok, op} <- fetch_op(params),
         {:ok, descriptor} <- Schema.fetch(server, ctx, relation),
         :ok <- authorize(server, descriptor, ctx) do
      write(server, descriptor, op, params, ctx)
    end
  end

  # ── request parsing ───────────────────────────────────────────────────────

  defp fetch_relation_param(params, method) do
    case params["relation"] do
      relation when is_binary(relation) and relation != "" ->
        {:ok, relation}

      _other ->
        {:error, Error.invalid_params("#{method} requires a relation name")}
    end
  end

  defp fetch_op(params) do
    case params["op"] do
      "insert" ->
        {:ok, :insert}

      "update" ->
        {:ok, :update}

      "delete" ->
        {:ok, :delete}

      other ->
        {:error,
         Error.invalid_params(
           "sql/modify op must be insert|update|delete, got: #{inspect(other)}"
         )}
    end
  end

  defp scan_opts(params) do
    with {:ok, columns} <- string_list(params["columns"], "columns"),
         {:ok, sort} <- decode_sort(params["sort"]),
         {:ok, limit} <- decode_limit(params["limit"]),
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      {:ok,
       %{
         "quals" => params["quals"] || [],
         "columns" => columns,
         "sort" => sort,
         "limit" => limit,
         "cursor" => cursor
       }}
    end
  end

  defp string_list(nil, _label), do: {:ok, nil}

  defp string_list(values, label) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, Error.invalid_params("#{label} must be a list of strings")}
    end
  end

  defp string_list(_other, label),
    do: {:error, Error.invalid_params("#{label} must be a list of strings")}

  defp decode_sort(nil), do: {:ok, []}

  defp decode_sort(sort) when is_list(sort) do
    Enum.reduce_while(sort, {:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        %{"column" => column, "direction" => direction}
        when is_binary(column) and direction in ["asc", "desc"] ->
          {:cont, {:ok, [{column, String.to_existing_atom(direction)} | acc]}}

        %{"column" => column} when is_binary(column) ->
          {:cont, {:ok, [{column, :asc} | acc]}}

        other ->
          {:halt,
           {:error,
            Error.invalid_params(
              "each sort entry needs a string \"column\" and an optional " <>
                "\"direction\" of asc|desc, got: #{inspect(other)}"
            )}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, %Error{}} = error -> error
    end
  end

  defp decode_sort(_other), do: {:error, Error.invalid_params("sort must be a list")}

  defp decode_limit(nil), do: {:ok, nil}

  defp decode_limit(limit) when is_integer(limit) and limit > 0,
    do: {:ok, min(limit, @max_limit)}

  defp decode_limit(other),
    do: {:error, Error.invalid_params("limit must be a positive integer, got: #{inspect(other)}")}

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(cursor) when is_binary(cursor), do: {:ok, cursor}

  defp decode_cursor(other),
    do: {:error, Error.invalid_params("cursor must be a string, got: #{inspect(other)}")}

  defp decode_quals(descriptor, opts) do
    Quals.decode(Map.get(opts, "quals"), columns: Enum.map(descriptor.columns, & &1.name))
  end

  defp check_required_quals(descriptor, quals) do
    supplied = MapSet.new(quals, & &1.column)

    case Enum.reject(descriptor.required_quals, &MapSet.member?(supplied, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.invalid_params(
           "relation #{descriptor.name} requires quals on #{Enum.join(missing, ", ")}"
         )}
    end
  end

  defp output_columns(descriptor, opts) do
    declared = Enum.map(descriptor.columns, & &1.name)

    case Map.get(opts, "columns") do
      nil -> declared
      [] -> declared
      requested -> Enum.filter(requested, &(&1 in declared))
    end
    |> case do
      [] -> declared
      columns -> columns
    end
  end

  # ── authorization ─────────────────────────────────────────────────────────

  # A tool-derived relation borrows the tool's verdict: the read path IS
  # `tools/call`, and a denied tool is already absent from the effective
  # catalog `Schema.fetch/3` consults, so there is no way to read through SQL
  # what one may not call. A dataset has no tool to borrow from and takes an
  # ACL subject of its own, `{:dataset, name}`.
  defp authorize(server, %{kind: :dataset, name: name}, ctx) do
    case Provider.resolve_provider(server, []) do
      nil ->
        :ok

      {provider, check_opts} ->
        if :dataset in Provider.supported_kinds(provider) do
          resource = %Resource{kind: :dataset, id: name}

          case Provider.check(provider, subject_for(ctx), resource, :scan, ctx, check_opts) do
            :allow -> :ok
            _deny -> {:error, Error.forbidden("Forbidden: dataset #{name}")}
          end
        else
          # A provider that does not recognise the dataset subject falls to the
          # provider's own default, which for a configured provider is deny.
          {:error, Error.forbidden("Forbidden: dataset #{name}")}
        end
    end
  end

  defp authorize(_server, _descriptor, _ctx), do: :ok

  defp subject_for(%{auth: %Principal{} = principal}), do: principal
  defp subject_for(_ctx), do: nil

  # ── reads ─────────────────────────────────────────────────────────────────

  defp read(server, %{source: {:catalog, kind}} = descriptor, quals, opts, ctx) do
    server
    |> Schema.catalog_rows(ctx, kind)
    |> Quals.apply(quals)
    |> sort_rows(Map.get(opts, "sort", []))
    |> page(descriptor, opts)
  end

  defp read(server, %{source: {:read_through, :prompt_messages}}, quals, _opts, ctx) do
    prompt = qual_value(quals, "prompt")
    arguments = qual_value(quals, "arguments") || %{}

    case Features.Prompts.get(
           server,
           %{"name" => prompt, "arguments" => arguments},
           ctx
         ) do
      {:ok, result} ->
        rows =
          result
          |> Map.get("messages", [])
          |> Enum.with_index()
          |> Enum.map(fn {message, idx} ->
            content = message["content"] || %{}

            %{
              "prompt" => prompt,
              "arguments" => arguments,
              "idx" => idx,
              "role" => message["role"],
              "content_type" => content["type"],
              "text" => content["text"],
              "content" => content,
              "description" => result["description"]
            }
          end)

        {:ok, Quals.apply(rows, quals), nil}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp read(server, %{source: {:read_through, :resource_contents}}, quals, _opts, ctx) do
    uris = qual_values(quals, "uri")

    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case Features.Resources.read(server, %{"uri" => uri}, ctx) do
        {:ok, result} ->
          rows =
            result
            |> Map.get("contents", [])
            |> Enum.with_index()
            |> Enum.map(fn {contents, idx} ->
              %{
                "uri" => contents["uri"] || uri,
                "idx" => idx,
                "mime_type" => contents["mimeType"],
                "text" => contents["text"],
                "blob" => contents["blob"],
                "meta" => contents["_meta"]
              }
            end)

          {:cont, {:ok, acc ++ rows}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Quals.apply(rows, quals), nil}
      {:error, %Error{}} = error -> error
    end
  end

  defp read(server, %{source: {:read_through, :completions}}, quals, _opts, ctx) do
    params = %{
      "ref" => qual_value(quals, "ref"),
      "argument" => %{
        "name" => qual_value(quals, "argument_name"),
        "value" => qual_value(quals, "argument_value") || ""
      }
    }

    case Features.Completion.complete(server, params, ctx) do
      {:ok, %{"completion" => completion}} ->
        values = completion["values"] || []

        rows =
          values
          |> Enum.with_index()
          |> Enum.map(fn {value, idx} ->
            %{
              "ref" => params["ref"],
              "argument_name" => params["argument"]["name"],
              "argument_value" => params["argument"]["value"],
              "value" => value,
              "idx" => idx,
              "total" => completion["total"],
              "has_more" => completion["hasMore"] == true
            }
          end)

        {:ok, Quals.apply(rows, quals), nil}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp read(server, %{source: {:tool, tool}} = descriptor, quals, _opts, ctx) do
    arguments = tool_arguments(descriptor, quals)

    case invoke_tool(server, tool, arguments, ctx) do
      {:ok, %ToolResult{} = result} -> {:ok, tool_rows(descriptor, arguments, result), nil}
      {:error, %Error{}} = error -> error
    end
  end

  defp read(_server, %{source: {:dataset, module}} = descriptor, quals, opts, ctx) do
    dataset_opts = %{
      quals: quals,
      columns: Map.get(opts, "columns"),
      sort: Map.get(opts, "sort", []),
      limit: Map.get(opts, "limit"),
      cursor: Map.get(opts, "cursor")
    }

    case dataset_scan(module, ctx, dataset_opts) do
      {:ok, rows, cursor} when is_list(rows) ->
        {:ok, Quals.apply(rows, quals), cursor}

      {:error, %Error{}} = error ->
        error

      other ->
        {:error,
         Error.internal(
           "dataset #{descriptor.name} returned #{inspect(other)} — expected " <>
             "{:ok, rows, cursor} | {:error, %Noizu.MCP.Error{}}"
         )}
    end
  end

  # D5, fail-closed per set: a dataset that raises takes down its own relation
  # and nothing else. `sql/schema` and every sibling dataset keep working.
  defp dataset_scan(module, ctx, opts) do
    module.scan(%{}, ctx, opts)
  rescue
    error ->
      {:error, Error.internal("dataset scan failed: #{Exception.message(error)}")}
  catch
    kind, reason ->
      {:error, Error.internal("dataset scan failed: #{inspect({kind, reason})}")}
  end

  defp qual_value(quals, column) do
    Enum.find_value(quals, fn
      %{column: ^column, op: :eq, value: value} -> {:ok, value}
      _other -> nil
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end

  defp qual_values(quals, column) do
    Enum.flat_map(quals, fn
      %{column: ^column, op: :eq, value: value} -> [value]
      %{column: ^column, op: :in, value: values} when is_list(values) -> values
      _other -> []
    end)
    |> Enum.uniq()
  end

  # ── tool relations ────────────────────────────────────────────────────────

  defp tool_arguments(descriptor, quals) do
    Enum.reduce(quals, %{}, fn
      %{column: column, op: :eq, value: value}, acc ->
        if column in descriptor.qual_columns, do: Map.put(acc, column, value), else: acc

      _other, acc ->
        acc
    end)
  end

  defp invoke_tool(server, tool, arguments, ctx) do
    case server
         |> Features.Tools.protocol_call(tool, arguments, ctx)
         |> Features.Tools.normalize(nil) do
      {:error, %Error{}} = error -> error
      %ToolResult{} = result -> {:ok, result}
    end
  rescue
    error -> {:error, Error.internal("tool scan failed: #{Exception.message(error)}")}
  end

  defp tool_rows(descriptor, arguments, %ToolResult{} = result) do
    base =
      Map.merge(arguments, %{
        "content" => Enum.map(result.content, &Content.to_map/1),
        "is_error" => result.is_error
      })

    declared = MapSet.new(descriptor.columns, & &1.name)

    case structured_rows(result.structured) do
      [] -> [base]
      rows -> Enum.map(rows, fn row -> Map.merge(base, take_declared(row, declared)) end)
    end
  end

  defp structured_rows(nil), do: []

  defp structured_rows(structured) when is_map(structured) do
    case Schema.array_of_objects(as_properties(structured)) do
      {name, _items} -> Enum.filter(Map.get(structured, name, []), &is_map/1)
      nil -> [structured]
    end
  end

  defp structured_rows(_other), do: []

  # A structured result is a value, not a schema; wrap each top-level entry so
  # the same "single array of objects" rule the schema used can be re-applied.
  defp as_properties(structured) do
    Map.new(structured, fn
      {key, [%{} | _] = value} ->
        {key, %{"type" => "array", "items" => %{"type" => "object", "properties" => %{}}}}
        |> then(fn {k, v} ->
          {k, put_in(v, ["items", "properties"], sample_properties(value))}
        end)

      {key, _value} ->
        {key, %{}}
    end)
  end

  defp sample_properties([first | _rest]) when is_map(first),
    do: Map.new(first, fn {key, _value} -> {key, %{}} end)

  defp sample_properties(_other), do: %{}

  defp take_declared(row, declared) when is_map(row) do
    row
    |> Enum.filter(fn {key, _value} -> is_binary(key) and MapSet.member?(declared, key) end)
    |> Map.new()
  end

  # ── writes ────────────────────────────────────────────────────────────────

  defp write(server, %{source: {:tool, tool}} = descriptor, :insert, params, ctx) do
    rows = params["rows"] || []

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      arguments = take_declared(row || %{}, MapSet.new(descriptor.qual_columns))

      case invoke_tool(server, tool, arguments, ctx) do
        {:ok, result} -> {:cont, {:ok, acc ++ tool_rows(descriptor, arguments, result)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, %{"rows" => rows}}
      {:error, %Error{}} = error -> error
    end
  end

  defp write(_server, %{kind: :tool, name: name}, op, _params, _ctx) do
    {:error, Error.invalid_request("relation #{name} does not support #{op}")}
  end

  defp write(_server, %{source: {:dataset, module}} = descriptor, op, params, ctx) do
    if op in module.__mcp_dataset__(:ops) do
      dataset_write(module, descriptor, op, params, ctx)
    else
      {:error, Error.method_not_found("sql/modify #{op} on relation #{descriptor.name}")}
    end
  end

  defp write(_server, descriptor, op, _params, _ctx) do
    {:error, Error.invalid_request("relation #{descriptor.name} is read-only (#{op})")}
  end

  defp dataset_write(module, descriptor, :insert, params, ctx) do
    rows = params["rows"] || []

    if is_list(rows) do
      module
      |> guarded(fn -> module.insert(rows, ctx) end)
      |> rows_result(descriptor)
    else
      {:error, Error.invalid_params("sql/modify insert requires a rows array")}
    end
  end

  defp dataset_write(module, descriptor, :update, params, ctx) do
    changes = params["changes"] || %{}

    with {:ok, quals} <- decode_quals(descriptor, params) do
      if is_map(changes) do
        module
        |> guarded(fn -> module.update(quals, changes, ctx) end)
        |> rows_result(descriptor)
      else
        {:error, Error.invalid_params("sql/modify update requires a changes object")}
      end
    end
  end

  defp dataset_write(module, descriptor, :delete, params, ctx) do
    with {:ok, quals} <- decode_quals(descriptor, params) do
      case guarded(module, fn -> module.delete(quals, ctx) end) do
        {:ok, count} when is_integer(count) and count >= 0 ->
          {:ok, %{"count" => count}}

        {:error, %Error{}} = error ->
          error

        other ->
          {:error,
           Error.internal(
             "dataset #{descriptor.name} delete/2 returned #{inspect(other)} — " <>
               "expected {:ok, non_neg_integer} | {:error, %Noizu.MCP.Error{}}"
           )}
      end
    end
  end

  defp rows_result({:ok, rows}, _descriptor) when is_list(rows), do: {:ok, %{"rows" => rows}}
  defp rows_result({:error, %Error{}} = error, _descriptor), do: error

  defp rows_result(other, descriptor) do
    {:error,
     Error.internal(
       "dataset #{descriptor.name} write returned #{inspect(other)} — " <>
         "expected {:ok, rows} | {:error, %Noizu.MCP.Error{}}"
     )}
  end

  defp guarded(_module, fun) do
    fun.()
  rescue
    error -> {:error, Error.internal("dataset write failed: #{Exception.message(error)}")}
  catch
    kind, reason -> {:error, Error.internal("dataset write failed: #{inspect({kind, reason})}")}
  end

  # ── ordering, paging, rendering ───────────────────────────────────────────

  defp sort_rows(rows, []), do: rows

  defp sort_rows(rows, sort) do
    Enum.sort(rows, fn left, right -> compare_rows(left, right, sort) != :gt end)
  end

  defp compare_rows(_left, _right, []), do: :eq

  defp compare_rows(left, right, [{column, direction} | rest]) do
    a = Map.get(left, column)
    b = Map.get(right, column)

    cond do
      a == b -> compare_rows(left, right, rest)
      direction == :desc and a > b -> :lt
      direction == :desc -> :gt
      a < b -> :lt
      true -> :gt
    end
  end

  # Offset paging for relations the library itself materializes. `limit`
  # governs the page size; the cursor is opaque and carries the next offset.
  defp page(rows, descriptor, opts) do
    if descriptor.limit do
      limit = Map.get(opts, "limit") || @default_limit

      case offset(Map.get(opts, "cursor")) do
        {:ok, offset} ->
          page = Enum.slice(rows, offset, limit)

          next =
            if offset + limit < length(rows),
              do: encode_offset(offset + limit),
              else: nil

          {:ok, page, next}

        :error ->
          {:error, Error.invalid_params("Invalid cursor")}
      end
    else
      {:ok, rows, nil}
    end
  end

  defp encode_offset(offset), do: Base.url_encode64("sql:#{offset}", padding: false)

  defp offset(nil), do: {:ok, 0}

  defp offset(cursor) when is_binary(cursor) do
    with {:ok, "sql:" <> rest} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} <- Integer.parse(rest) do
      {:ok, offset}
    else
      _other -> :error
    end
  end

  defp offset(_other), do: :error

  @doc """
  Render map rows positionally against `columns`, filling `nil` for any column
  a row omits. Public because the conformance suite asserts against it.
  """
  @spec render_rows([String.t()], [map()], String.t() | nil) :: map()
  def render_rows(columns, rows, next_cursor) do
    %{
      "columns" => columns,
      "rows" => Enum.map(rows, fn row -> Enum.map(columns, &Map.get(row, &1)) end),
      "nextCursor" => next_cursor
    }
  end

  defp invalid_return(method, other) do
    Error.internal("#{method} handler returned #{inspect(other)}")
  end
end
