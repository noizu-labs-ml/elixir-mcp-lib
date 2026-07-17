defmodule Noizu.MCP.Types.Tool do
  @moduledoc """
  An MCP tool definition as advertised by `tools/list`.

  `annotations` accepts snake_case atom keys (`:read_only_hint`,
  `:destructive_hint`, `:idempotent_hint`, `:open_world_hint`, `:title`) and
  renders them in the camelCase wire format.

  `description` and `title` may be a plain `String.t()` or a
  `Noizu.MCP.Description.t()` (a verbosity variant set); `to_map/2` resolves them
  through a `Noizu.MCP.RenderCtx`. When `input_fields`/`output_fields` are
  present (DSL-declared schemas), `to_map/2` re-renders their JSON Schema through
  the context so field descriptions track the requested verbosity too; otherwise
  the pre-compiled `input_schema`/`output_schema` maps are used verbatim. The
  arity-1 `to_map/1` uses `RenderCtx.default/0`, so plain-string tools render
  exactly as before.
  """

  alias Noizu.MCP.{Description, RenderCtx}
  alias Noizu.MCP.Server.Tool.Fields

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | Description.t() | nil,
          description: String.t() | Description.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          input_fields: list() | nil,
          output_fields: list() | nil,
          annotations: map() | keyword() | nil,
          icons: [map()] | nil,
          meta: map() | nil
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :title,
    :description,
    :output_schema,
    :input_fields,
    :output_fields,
    :annotations,
    :icons,
    :meta,
    input_schema: %{"type" => "object"}
  ]

  @annotation_keys %{
    title: "title",
    read_only_hint: "readOnlyHint",
    destructive_hint: "destructiveHint",
    idempotent_hint: "idempotentHint",
    open_world_hint: "openWorldHint"
  }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool), do: to_map(tool, RenderCtx.default())

  @spec to_map(t(), RenderCtx.t()) :: map()
  def to_map(%__MODULE__{} = tool, %RenderCtx{} = ctx) do
    %{"name" => tool.name, "inputSchema" => render_input_schema(tool, ctx)}
    |> put_unless_nil("title", Description.resolve(tool.title, ctx))
    |> put_unless_nil("description", Description.resolve(tool.description, ctx))
    |> put_unless_nil("outputSchema", render_output_schema(tool, ctx))
    |> put_unless_nil("annotations", encode_annotations(tool.annotations))
    |> put_unless_nil("icons", tool.icons)
    |> put_unless_nil("_meta", tool.meta)
  end

  defp render_input_schema(%__MODULE__{input_fields: fields}, ctx) when is_list(fields),
    do: Fields.to_json_schema(fields, ctx)

  defp render_input_schema(%__MODULE__{input_schema: schema}, _ctx), do: schema

  defp render_output_schema(%__MODULE__{output_fields: fields}, ctx) when is_list(fields),
    do: Fields.to_json_schema(fields, ctx)

  defp render_output_schema(%__MODULE__{output_schema: schema}, _ctx), do: schema

  @spec from_map(map()) :: t()
  def from_map(%{"name" => name} = map) do
    %__MODULE__{
      name: name,
      title: map["title"],
      description: map["description"],
      input_schema: map["inputSchema"] || %{"type" => "object"},
      output_schema: map["outputSchema"],
      annotations: map["annotations"],
      icons: map["icons"],
      meta: map["_meta"]
    }
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(%{} = annotations), do: annotations

  defp encode_annotations(annotations) when is_list(annotations) do
    Map.new(annotations, fn {key, value} ->
      case Map.fetch(@annotation_keys, key) do
        {:ok, wire_key} -> {wire_key, value}
        :error -> raise ArgumentError, "unknown tool annotation: #{inspect(key)}"
      end
    end)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
