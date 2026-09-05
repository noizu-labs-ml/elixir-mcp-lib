defmodule Noizu.MCP.SQL.Schema do
  @moduledoc """
  The `sql/schema` payload: every relation a server projects into SQL, with
  typed columns, pushdown declarations and an invoke kind (PRD-9 §4.4).

  Five invoke kinds, per ADR-005:

    * `catalog` — `tools`, `prompts`, `resources`: the listable surfaces, read
      straight from the live catalog;
    * `prompt` — `prompt_arguments`, `prompt_messages`, `completions`: derived
      from or read through the prompt methods;
    * `resource` — `resource_templates`, `resource_contents`;
    * `tool` — one relation per effective tool, columns derived from its
      `inputSchema`/`outputSchema`;
    * `dataset` — the relations a server registered with `dataset/2`.

  Everything but `dataset` is **derived**, so a server that registers no
  datasets and merely opts in with `sql: true` still answers `sql/schema` with
  a full description of its surface — `mode 'sql'` is never worse than
  `mode 'generic'`.

  Derivation goes through the one resolver (D1): tools through
  `Noizu.MCP.Toolset.catalog/3`, prompts through
  `Noizu.MCP.Server.Features.Prompts`, resources through
  `Noizu.MCP.Server.Features.Resources`. There is no parallel registry, and
  the tool section describes the *effective* tools for the requesting
  principal — a tool the caller may not call is not in the schema (D2).
  """

  alias Noizu.MCP.{Error, RenderCtx, Toolset}
  alias Noizu.MCP.SQL.Types
  alias Noizu.MCP.Server.Features
  alias Noizu.MCP.Types.{Prompt, Resource, ResourceTemplate, Tool}

  @version 1

  @typedoc "A relation descriptor. `:source` is internal and never reaches the wire."
  @type relation :: %{
          name: String.t(),
          kind: :catalog | :dataset | :tool | :resource | :prompt,
          columns: [Noizu.MCP.Server.Dataset.column()],
          primary_key: [String.t()],
          writable: boolean(),
          qual_columns: [String.t()],
          required_quals: [String.t()],
          sort: boolean(),
          limit: boolean(),
          tool: String.t() | nil,
          read_only: boolean() | nil,
          source: term()
        }

  # Relation names the derived schema always owns. A dataset may not take one.
  @reserved [
    "tools",
    "prompts",
    "prompt_arguments",
    "prompt_messages",
    "completions",
    "resources",
    "resource_templates",
    "resource_contents"
  ]

  @doc "The `sql/*` protocol version this library speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Relation names the derived schema owns. A dataset registered under one of
  these is a compile-time error (FR-9.6).
  """
  @spec reserved_relations() :: [String.t()]
  def reserved_relations, do: @reserved

  @doc """
  Build the `sql/schema` payload for `server` under `ctx`.

  Options:

    * `:include_hidden` — include datasets registered `hidden: true`
      (they stay scannable by exact name either way, mirroring hidden tools).
  """
  @spec build(module(), Noizu.MCP.Ctx.t() | nil, keyword()) :: {:ok, map()}
  def build(server, ctx, opts \\ []) do
    relations = relations(server, ctx, opts)
    {:ok, %{"version" => @version, "relations" => Enum.map(relations, &to_wire/1)}}
  end

  @doc "The relation descriptors behind `build/3`, `:source` intact."
  @spec relations(module(), Noizu.MCP.Ctx.t() | nil, keyword()) :: [relation()]
  def relations(server, ctx, opts \\ []) do
    catalog_relations() ++ tool_relations(server, ctx) ++ dataset_relations(server, opts)
  end

  @doc """
  Find one relation by name. Hidden datasets resolve here — hiding governs the
  schema listing, not scannability.
  """
  @spec fetch(module(), Noizu.MCP.Ctx.t() | nil, String.t()) ::
          {:ok, relation()} | {:error, Error.t()}
  def fetch(server, ctx, name) when is_binary(name) do
    case Enum.find(relations(server, ctx, include_hidden: true), &(&1.name == name)) do
      nil -> {:error, Error.invalid_params("Unknown relation: #{name}")}
      relation -> {:ok, relation}
    end
  end

  def fetch(_server, _ctx, other),
    do: {:error, Error.invalid_params("relation must be a string, got: #{inspect(other)}")}

  @doc "Render a relation descriptor to its wire map."
  @spec to_wire(relation()) :: map()
  def to_wire(relation) do
    %{
      "name" => relation.name,
      "kind" => Atom.to_string(relation.kind),
      "columns" => Enum.map(relation.columns, &column_to_wire/1),
      "primary_key" => relation.primary_key,
      "writable" => relation.writable,
      "qual_columns" => relation.qual_columns,
      "required_quals" => relation.required_quals,
      "sort" => relation.sort,
      "limit" => relation.limit
    }
    |> then(fn map ->
      if relation.tool, do: Map.put(map, "tool", relation.tool), else: map
    end)
    |> then(fn map ->
      if is_nil(relation.read_only), do: map, else: Map.put(map, "read_only", relation.read_only)
    end)
  end

  defp column_to_wire(column) do
    Types.to_wire(column.type)
    |> Map.merge(%{
      "name" => column.name,
      "nullable" => Map.get(column, :nullable, true),
      "description" => Map.get(column, :description)
    })
  end

  # ── datasets ──────────────────────────────────────────────────────────────

  @doc """
  The datasets registered on `server`, as `{module, registration_opts, name,
  hidden?}`. The wire name is the registration's `:name` when given, else
  `info().name`.
  """
  @spec registered_datasets(module()) :: [{module(), keyword(), String.t(), boolean()}]
  def registered_datasets(server) do
    server
    |> registrations()
    |> Enum.map(fn {module, entry_opts} ->
      {module, entry_opts, dataset_name(module, entry_opts), entry_opts[:hidden] == true}
    end)
  end

  @doc """
  A dataset's effective wire name: the registration's `:name`, else
  `info().name`. Usable at compile time, which is what makes the
  reserved-name collision check possible.
  """
  @spec dataset_name(module(), keyword()) :: String.t()
  def dataset_name(module, entry_opts) do
    case entry_opts[:name] do
      name when is_binary(name) -> name
      _other -> module.info().name
    end
  end

  defp registrations(server) do
    server.__mcp__(:datasets)
  rescue
    _error -> []
  end

  defp dataset_relations(server, opts) do
    include_hidden = Keyword.get(opts, :include_hidden, false)

    server
    |> registered_datasets()
    |> Enum.reject(fn {_module, _entry_opts, _name, hidden?} ->
      hidden? and not include_hidden
    end)
    |> Enum.map(&dataset_relation/1)
  end

  defp dataset_relation({module, _entry_opts, name, _hidden?}) do
    info = Noizu.MCP.Server.Dataset.validate_info!(module, module.info())
    columns = Noizu.MCP.Server.Dataset.validate_columns!(module, module.columns())
    column_names = Enum.map(columns, & &1.name)

    %{
      name: name,
      kind: :dataset,
      columns: columns,
      primary_key: info.primary_key,
      writable: info.writable and module.__mcp_dataset__(:ops) != [],
      qual_columns: column_names,
      required_quals: [],
      sort: true,
      limit: true,
      tool: nil,
      read_only: nil,
      source: {:dataset, module}
    }
  end

  # ── tool relations ────────────────────────────────────────────────────────

  @doc """
  The relation name for a tool: `tool_` plus the tool's name lowered to a
  PostgreSQL identifier (non-identifier characters become `_`, truncated to
  the 63-byte limit).
  """
  @spec tool_relation_name(String.t()) :: String.t()
  def tool_relation_name(tool_name) do
    slug =
      tool_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/u, "_")

    binary_part("tool_" <> slug, 0, min(byte_size("tool_" <> slug), 63))
  end

  defp tool_relations(server, ctx) do
    server
    |> effective_tools(ctx)
    |> Enum.map(&tool_relation/1)
  end

  @doc """
  The effective, visible tool definitions for `ctx` — the same materialization
  `tools/list` performs, ACL included (D1/D2). A toolset that fails to
  materialize yields `[]`: the SQL surface loses its tool relations, the
  server stays healthy (D5).
  """
  @spec effective_tools(module(), Noizu.MCP.Ctx.t() | nil) :: [Tool.t()]
  def effective_tools(server, ctx) do
    toolset = Features.Tools.select_toolset(server, ctx)

    case Toolset.catalog(toolset, ctx, []) do
      {:ok, entries, _version} ->
        entries |> Enum.filter(& &1.visible) |> Enum.map(& &1.definition)

      {:error, %Error{}} ->
        []
    end
  rescue
    _error -> []
  end

  defp tool_relation(%Tool{} = tool) do
    wire = Tool.to_map(tool, RenderCtx.default())
    input_columns = schema_columns(wire["inputSchema"])
    output_columns = output_columns(wire["outputSchema"])

    columns =
      (input_columns ++ output_columns)
      |> Enum.uniq_by(& &1.name)
      |> Kernel.++([
        %{name: "content", type: :jsonb, nullable: true, description: "Raw tool result content"},
        %{name: "is_error", type: :boolean, nullable: true, description: "Tool reported an error"}
      ])
      |> Enum.uniq_by(& &1.name)

    required = List.wrap(get_in(wire, ["inputSchema", "required"]))
    annotations = wire["annotations"] || %{}

    %{
      name: tool_relation_name(tool.name),
      kind: :tool,
      columns: columns,
      primary_key: [],
      writable: true,
      qual_columns: Enum.map(input_columns, & &1.name),
      required_quals: Enum.filter(Enum.map(input_columns, & &1.name), &(&1 in required)),
      sort: false,
      limit: false,
      tool: tool.name,
      read_only: annotations["readOnlyHint"] == true,
      source: {:tool, tool.name}
    }
  end

  defp schema_columns(%{"properties" => properties}) when is_map(properties) do
    properties
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, property} ->
      %{
        name: name,
        type: Types.from_json_schema(property),
        nullable: true,
        description: is_map(property) && property["description"]
      }
    end)
    |> Enum.map(fn column ->
      %{column | description: if(is_binary(column.description), do: column.description)}
    end)
  end

  defp schema_columns(_schema), do: []

  # PRD-8 §4.2: a single top-level array-of-objects property flattens to one
  # row per element; anything else is one row of top-level properties.
  defp output_columns(%{"properties" => properties} = schema) when is_map(properties) do
    case array_of_objects(properties) do
      {_name, items} -> schema_columns(items)
      nil -> schema_columns(schema)
    end
  end

  defp output_columns(_schema), do: []

  @doc false
  # The single top-level "array of objects" property of an output schema, or
  # nil when there is none or more than one. Shared with the scan path so the
  # declared columns and the produced rows cannot disagree.
  @spec array_of_objects(map()) :: {String.t(), map()} | nil
  def array_of_objects(properties) when is_map(properties) do
    properties
    |> Enum.filter(fn
      {_name, %{"type" => "array", "items" => %{"type" => "object"} = items}} ->
        is_map(items["properties"])

      _other ->
        false
    end)
    |> case do
      [{name, %{"items" => items}}] -> {name, items}
      _other -> nil
    end
  end

  # ── catalog & read-through relations ──────────────────────────────────────

  @doc """
  The derived, always-present relations: the three catalog relations plus the
  prompt- and resource-derived ones. Their column lists mirror the FDW's
  generic mode exactly, so a `sql`-mode and a `generic`-mode client see the
  same tables.
  """
  @spec catalog_relations() :: [relation()]
  def catalog_relations do
    [
      relation("tools", :catalog, tools_columns(),
        primary_key: ["name"],
        qual_columns: ["name"],
        source: {:catalog, :tools}
      ),
      relation("prompts", :catalog, prompts_columns(),
        primary_key: ["name"],
        qual_columns: ["name"],
        source: {:catalog, :prompts}
      ),
      relation("resources", :catalog, resources_columns(),
        primary_key: ["uri"],
        qual_columns: ["uri"],
        source: {:catalog, :resources}
      ),
      relation("prompt_arguments", :prompt, prompt_arguments_columns(),
        primary_key: ["prompt", "name"],
        qual_columns: ["prompt", "name"],
        source: {:catalog, :prompt_arguments}
      ),
      relation("resource_templates", :resource, resource_templates_columns(),
        primary_key: ["uri_template"],
        qual_columns: ["uri_template"],
        source: {:catalog, :resource_templates}
      ),
      relation("prompt_messages", :prompt, prompt_messages_columns(),
        primary_key: ["prompt", "idx"],
        qual_columns: ["prompt", "arguments"],
        required_quals: ["prompt"],
        sort: false,
        limit: false,
        source: {:read_through, :prompt_messages}
      ),
      relation("resource_contents", :resource, resource_contents_columns(),
        primary_key: ["uri", "idx"],
        qual_columns: ["uri"],
        required_quals: ["uri"],
        sort: false,
        limit: false,
        source: {:read_through, :resource_contents}
      ),
      relation("completions", :prompt, completions_columns(),
        primary_key: ["ref", "argument_name", "argument_value", "idx"],
        qual_columns: ["ref", "argument_name", "argument_value"],
        required_quals: ["ref", "argument_name", "argument_value"],
        sort: false,
        limit: false,
        source: {:read_through, :completions}
      )
    ]
  end

  defp relation(name, kind, columns, opts) do
    %{
      name: name,
      kind: kind,
      columns: columns,
      primary_key: Keyword.get(opts, :primary_key, []),
      writable: false,
      qual_columns: Keyword.get(opts, :qual_columns, []),
      required_quals: Keyword.get(opts, :required_quals, []),
      sort: Keyword.get(opts, :sort, false),
      limit: Keyword.get(opts, :limit, true),
      tool: nil,
      read_only: nil,
      source: Keyword.fetch!(opts, :source)
    }
  end

  defp column(name, type, description),
    do: %{name: name, type: type, nullable: true, description: description}

  defp tools_columns do
    [
      column("name", :text, "Tool name"),
      column("title", :text, "Human-readable title"),
      column("description", :text, "Tool description"),
      column("input_schema", :jsonb, "JSON Schema for the tool's arguments"),
      column("output_schema", :jsonb, "JSON Schema for the tool's structured output"),
      column("annotations", :jsonb, "Tool annotations"),
      column("read_only", :boolean, "annotations.readOnlyHint"),
      column("destructive", :boolean, "annotations.destructiveHint"),
      column("idempotent", :boolean, "annotations.idempotentHint"),
      column("open_world", :boolean, "annotations.openWorldHint"),
      column("meta", :jsonb, "Tool _meta")
    ]
  end

  defp prompts_columns do
    [
      column("name", :text, "Prompt name"),
      column("title", :text, "Human-readable title"),
      column("description", :text, "Prompt description"),
      column("meta", :jsonb, "Prompt _meta")
    ]
  end

  defp prompt_arguments_columns do
    [
      column("prompt", :text, "Owning prompt name"),
      column("name", :text, "Argument name"),
      column("description", :text, "Argument description"),
      column("required", :boolean, "Argument is required"),
      column("idx", :bigint, "Position within the prompt's argument list")
    ]
  end

  defp resources_columns do
    [
      column("uri", :text, "Resource URI"),
      column("name", :text, "Resource name"),
      column("title", :text, "Human-readable title"),
      column("description", :text, "Resource description"),
      column("mime_type", :text, "Resource MIME type"),
      column("size", :bigint, "Resource size in bytes"),
      column("annotations", :jsonb, "Resource annotations"),
      column("meta", :jsonb, "Resource _meta")
    ]
  end

  defp resource_templates_columns do
    [
      column("uri_template", :text, "RFC 6570 URI template"),
      column("name", :text, "Template name"),
      column("title", :text, "Human-readable title"),
      column("description", :text, "Template description"),
      column("mime_type", :text, "Template MIME type"),
      column("annotations", :jsonb, "Template annotations"),
      column("meta", :jsonb, "Template _meta")
    ]
  end

  defp resource_contents_columns do
    [
      column("uri", :text, "Resource URI (qual required)"),
      column("idx", :bigint, "Index within the contents array"),
      column("mime_type", :text, "Content MIME type"),
      column("text", :text, "Text content, NULL for blobs"),
      column("blob", :text, "Base64 blob content, NULL for text"),
      column("meta", :jsonb, "Content _meta")
    ]
  end

  defp prompt_messages_columns do
    [
      column("prompt", :text, "Prompt name (qual required)"),
      column("arguments", :jsonb, "Prompt arguments, defaults to {}"),
      column("idx", :bigint, "Index within the rendered message list"),
      column("role", :text, "Message role"),
      column("content_type", :text, "text | image | audio | resource"),
      column("text", :text, "Text content when the block is text"),
      column("content", :jsonb, "Full content block"),
      column("description", :text, "The prompt's own description")
    ]
  end

  defp completions_columns do
    [
      column("ref", :jsonb, "Completion ref (qual required)"),
      column("argument_name", :text, "Argument being completed (qual required)"),
      column("argument_value", :text, "Partial value (qual required)"),
      column("value", :text, "One completion candidate"),
      column("idx", :bigint, "Position within the candidate list"),
      column("total", :bigint, "Total candidates available"),
      column("has_more", :boolean, "More candidates exist beyond this page")
    ]
  end

  # ── catalog rows ──────────────────────────────────────────────────────────

  @doc """
  Rows for a derived relation, as maps keyed by column name. Everything here
  reads the same wire maps the corresponding list method emits, so a catalog
  relation and its `*/list` method can never drift.
  """
  @spec catalog_rows(module(), Noizu.MCP.Ctx.t() | nil, atom()) :: [map()]
  def catalog_rows(server, ctx, :tools) do
    server
    |> effective_tools(ctx)
    |> Enum.map(fn tool ->
      wire = Tool.to_map(tool, RenderCtx.default())
      annotations = wire["annotations"]

      %{
        "name" => wire["name"],
        "title" => wire["title"],
        "description" => wire["description"],
        "input_schema" => wire["inputSchema"],
        "output_schema" => wire["outputSchema"],
        "annotations" => annotations,
        "read_only" => annotations && annotations["readOnlyHint"],
        "destructive" => annotations && annotations["destructiveHint"],
        "idempotent" => annotations && annotations["idempotentHint"],
        "open_world" => annotations && annotations["openWorldHint"],
        "meta" => wire["_meta"]
      }
    end)
  end

  def catalog_rows(server, ctx, :prompts) do
    server
    |> list_prompts(ctx)
    |> Enum.map(fn prompt ->
      wire = Prompt.to_map(prompt)

      %{
        "name" => wire["name"],
        "title" => wire["title"],
        "description" => wire["description"],
        "meta" => wire["_meta"]
      }
    end)
  end

  def catalog_rows(server, ctx, :prompt_arguments) do
    server
    |> list_prompts(ctx)
    |> Enum.flat_map(fn prompt ->
      prompt.arguments
      |> Enum.with_index()
      |> Enum.map(fn {argument, idx} ->
        %{
          "prompt" => prompt.name,
          "name" => argument.name,
          "description" => argument.description,
          "required" => argument.required,
          "idx" => idx
        }
      end)
    end)
  end

  def catalog_rows(server, ctx, :resources) do
    server
    |> list_resources(ctx)
    |> Enum.map(fn resource ->
      wire = Resource.to_map(resource)

      %{
        "uri" => wire["uri"],
        "name" => wire["name"],
        "title" => wire["title"],
        "description" => wire["description"],
        "mime_type" => wire["mimeType"],
        "size" => wire["size"],
        "annotations" => wire["annotations"],
        "meta" => wire["_meta"]
      }
    end)
  end

  def catalog_rows(server, ctx, :resource_templates) do
    server
    |> list_resource_templates(ctx)
    |> Enum.map(fn template ->
      wire = ResourceTemplate.to_map(template)

      %{
        "uri_template" => wire["uriTemplate"],
        "name" => wire["name"],
        "title" => wire["title"],
        "description" => wire["description"],
        "mime_type" => wire["mimeType"],
        "annotations" => wire["annotations"],
        "meta" => wire["_meta"]
      }
    end)
  end

  @doc false
  @spec list_prompts(module(), Noizu.MCP.Ctx.t() | nil) :: [Prompt.t()]
  def list_prompts(server, ctx), do: drain(server, :handle_list_prompts, ctx)

  @doc false
  @spec list_resources(module(), Noizu.MCP.Ctx.t() | nil) :: [Resource.t()]
  def list_resources(server, ctx), do: drain(server, :handle_list_resources, ctx)

  @doc false
  @spec list_resource_templates(module(), Noizu.MCP.Ctx.t() | nil) :: [ResourceTemplate.t()]
  def list_resource_templates(server, ctx),
    do: drain(server, :handle_list_resource_templates, ctx)

  # Follow the callback's cursors to exhaustion. A server that does not
  # implement the callback has no rows for that relation — the relation is
  # still declared, and scans of it are empty rather than an error, matching
  # the FDW's generic-mode treatment of an absent list method.
  defp drain(server, callback, ctx), do: drain(server, callback, ctx, nil, [], 0)

  defp drain(_server, _callback, _ctx, _cursor, acc, depth) when depth > 1_000, do: acc

  defp drain(server, callback, ctx, cursor, acc, depth) do
    case Kernel.apply(server, callback, [cursor, ctx]) do
      {:ok, items, nil} -> acc ++ items
      {:ok, items, next} -> drain(server, callback, ctx, next, acc ++ items, depth + 1)
      _other -> acc
    end
  rescue
    error in [UndefinedFunctionError] ->
      if error.module == server and error.function == callback do
        acc
      else
        reraise error, __STACKTRACE__
      end
  end
end
