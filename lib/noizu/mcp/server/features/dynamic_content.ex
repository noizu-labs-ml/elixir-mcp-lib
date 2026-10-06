defmodule Noizu.MCP.Server.Features.DynamicContent do
  @moduledoc """
  CRUD-managed resources & prompts backed by a VFS mount (`content/1,2`).

  The `content` registration mounts a VFS backend for CRUD through the
  existing `vfs/*` tooling *and* bridges the mount's files into the
  resources and prompts surfaces, so a client (or an admin pipeline) can
  add, edit, and remove live MCP resources and prompts by writing files:

      defmodule MyApp.MCP do
        use Noizu.MCP.Server, name: "my-app", version: "1.0.0"

        resource MyApp.MCP.StaticAbout
        prompt MyApp.MCP.StaticCodeReview

        content {Noizu.MCP.VFS.File, root: "/srv/content"},
          resources: "/resources",
          prompts: "/prompts",
          uri_scheme: "content",
          write_scope: "content:write"
      end

  All prefix options are optional — declare only what you expose; at least
  one is required. With the tree above:

    * `/resources/**` files advertise on `resources/list` as
      `content://<path-under-/resources>` (e.g. `/resources/guide.md` →
      `content://guide.md`) and read via `resources/read` straight off the
      backend (cache-aware, like any VFS read).
    * `/prompts/**` files are JSON prompt definitions —
      `{"name", "description", "arguments": [{"name", "description",
      "required"}], "messages": [{"role", "content"}]}` — advertised on
      `prompts/list` and rendered by `prompts/get` with `{{argument}}`
      placeholders substituted from the request's string-keyed arguments
      (the same shape the static prompt DSL produces).
    * Static registrations merge in front of the dynamic entries; static
      wins on a name/URI collision.
    * Every successful `vfs/write`, `vfs/create`, or `vfs/remove` under a
      content prefix fans out `notify_resource_updated/1` (resources
      prefix) and `notify_changed/1` (`:resources` / `:prompts`), so
      subscribed sessions and list caches invalidate exactly like static
      component changes.
    * When `write_scope:` is set, mutating `vfs/*` operations on the
      mount's prefixes require that scope in the caller's claims
      (`ctx.assigns.auth_claims`, the same plumbing the JWT verifier uses)
      — missing scope is `:eacces`. Reads stay under the existing auth.
      Scopes are read with `Noizu.MCP.Auth.JWTVerifier.scopes/1` (the
      canonical `scope` / `scopes` / `scp` claim shapes, string or list)
      and matched exact or trailing-`*` glob. A granted bare `"*"` covers
      nothing except a `write_scope` that is itself `"*"` — a superuser
      glob in a token must not silently unlock every content write.

  Registration opts beyond the bridge's own (`:resources`, `:prompts`,
  `:uri_scheme`, `:write_scope`) travel to the backend through
  `ctx.assigns[:vfs_opts]` unchanged — a `content` registration *is* a
  `vfs` registration plus the bridge.
  """

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.{Pagination, Prompts, Resources}
  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.Types
  alias Noizu.MCP.Types.{Prompt, ResourceContents}

  # Extension map for backends that do not answer `mime_type/2`.
  @default_mime_types %{
    ".txt" => "text/plain",
    ".md" => "text/markdown",
    ".html" => "text/html",
    ".css" => "text/css",
    ".js" => "text/javascript",
    ".json" => "application/json",
    ".xml" => "application/xml",
    ".yaml" => "application/yaml",
    ".yml" => "application/yaml",
    ".ex" => "text/x-elixir",
    ".exs" => "text/x-elixir",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".svg" => "image/svg+xml"
  }

  @placeholder ~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

  # ── registration config ───────────────────────────────────────────────────

  @doc "The server's `content/1,2` registrations: `[{backend, opts}]`."
  # ⟦𓆒⟧ configs
  def configs(server) do
    server.__mcp__(:content)
  rescue
    UndefinedFunctionError -> []
  end

  # Prefix paths this registration exposes (normalized to absolute form).
  defp prefixes(opts),
    do: [opts[:resources], opts[:prompts]] |> Enum.reject(&is_nil/1) |> Enum.map(&norm/1)

  defp norm("/" <> _ = prefix), do: String.trim_trailing(prefix, "/")
  defp norm(prefix) when is_binary(prefix), do: "/" <> String.trim_trailing(prefix, "/")

  defp under?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp match_prefix(opts, path), do: Enum.find(prefixes(opts), &under?(path, &1))

  # ── mount routing (called from Features.VFS) ──────────────────────────────

  @doc """
  Pick the mount for a `vfs/*` path: a content registration whose prefix
  covers `path` wins; otherwise the first *plain* `vfs/1,2` registration
  (the first-wins rule — unchanged for servers that mount a vfs backend
  directly). A content mount never serves a path outside its declared
  prefixes: on a content-only server an undeclared path resolves to no
  mount at all rather than falling through to the content backend ungated.
  `nil`/blank paths resolve to the first registered backend.
  """
  # ⟦𓆒⟧ mount_for
  def mount_for(_server, mounts, nil), do: first_mount(mounts)

  def mount_for(server, mounts, path) when is_binary(path) do
    Enum.find_value(configs(server), fn {backend, opts} ->
      if Enum.any?(prefixes(opts), &under?(path, &1)), do: {backend, opts}
    end) || plain_mount(mounts, server)
  end

  defp first_mount([{backend, opts} | _]), do: {backend, opts}
  defp first_mount(_), do: nil

  # The first registration that is not a content mount. The terms match
  # `configs/1` exactly — `use Noizu.MCP.Server` appends the content
  # registrations to `__mcp__(:vfs)` verbatim.
  defp plain_mount(mounts, server) do
    content = configs(server)
    Enum.find(mounts, &(&1 not in content))
  end

  # Registration opts travel to the backend via ctx assigns — same plumbing
  # `Features.VFS` uses for `vfs/*` ops.
  defp opts_ctx(ctx, []), do: ctx
  defp opts_ctx(ctx, opts), do: Ctx.assign(ctx, :vfs_opts, opts)

  # ── write gating ──────────────────────────────────────────────────────────

  @doc """
  Gate mutating `vfs/*` operations on content prefixes: when the covering
  registration declares `write_scope:`, the caller's claims
  (`ctx.assigns.auth_claims`) must hold that scope — exact or trailing-`*`
  glob, mirroring `Noizu.MCP.Auth.Principal.has_scope?/2`. Missing scope is
  `:eacces`; paths outside every content prefix pass untouched.
  """
  # ⟦𓆒⟧ write_gate
  def write_gate(server, path, ctx) do
    case Enum.find_value(configs(server), fn {_backend, opts} ->
           scope = opts[:write_scope]
           scope && match_prefix(opts, path) && scope
         end) do
      nil -> :ok
      scope -> if scope_held?(ctx, scope), do: :ok, else: {:error, :eacces}
    end
  end

  defp scope_held?(ctx, scope) do
    claims = (is_struct(ctx, Ctx) && ctx.assigns[:auth_claims]) || nil
    Enum.any?(scopes(claims), &scope_covers?(&1, scope))
  end

  # A bare `"*"` grant covers nothing but a `write_scope` of `"*"` itself —
  # a superuser glob in a token must not silently unlock every content write.
  defp scope_covers?("*", "*"), do: true
  defp scope_covers?("*", _scope), do: false

  defp scope_covers?(granted, scope) do
    cond do
      granted == scope -> true
      String.ends_with?(granted, "*") -> String.starts_with?(scope, binary_part(granted, 0, byte_size(granted) - 1))
      true -> false
    end
  end

  # The canonical claim shape (`Noizu.MCP.Auth.JWTVerifier.scopes/1`): the
  # space-joined `scope` claim or a `scopes`/`scp` list, string- or
  # atom-keyed. Basic/Password verifiers stamp their granted scopes into the
  # same `scope` claim, so they reach this gate unchanged.
  defp scopes(claims) when is_map(claims) do
    case Noizu.MCP.Auth.JWTVerifier.scopes(claims) do
      [] -> atom_scopes(claims)
      scopes -> scopes
    end
  end

  defp scopes(_), do: []

  # The pre-canonical atom-keyed shapes still count.
  defp atom_scopes(%{scopes: scopes}) when is_list(scopes), do: Enum.map(scopes, &to_string/1)
  defp atom_scopes(%{scp: scopes}) when is_list(scopes), do: Enum.map(scopes, &to_string/1)
  defp atom_scopes(_), do: []

  # ── change fan-out (called from Features.VFS after a successful mutation) ─

  @doc """
  Fan a successful mutation under a content prefix out to the server's
  notification surface: `notify_resource_updated/1` +
  `notify_changed(:resources)` for the resources prefix,
  `notify_changed(:prompts)` for the prompts prefix. Mutations outside
  every content prefix are a no-op.
  """
  # ⟦𓆒⟧ after_mutation
  def after_mutation(server, path) do
    for {_backend, opts} <- configs(server),
        match = match_prefix(opts, path) do
      if opts[:resources] && norm(opts[:resources]) == match do
        notify(server, :notify_resource_updated, [dynamic_uri(opts, path)])
        notify(server, :notify_changed, [:resources])
      else
        notify(server, :notify_changed, [:prompts])
      end
    end

    :ok
  end

  defp notify(server, fun, args) do
    apply(server, fun, args)
    :ok
  rescue
    # UndefinedFunctionError: a bare module without the server DSL. ArgumentError:
    # the server's supervision tree (and its session Registry) is not running.
    UndefinedFunctionError -> :ok
    ArgumentError -> :ok
  end

  # ── resources ─────────────────────────────────────────────────────────────

  @doc "Default `handle_list_resources` over static registrations + content mounts."
  # ⟦𓆒⟧ list_resources
  def list_resources(server, resources, templates, cursor, ctx) do
    case dynamic_resources(server, ctx) do
      [] ->
        Resources.list_registered(resources, templates, cursor, ctx)

      dynamic ->
        with {:ok, static, _next} <- Resources.list_registered(resources, templates, nil, ctx) do
          Pagination.paginate(static ++ dynamic, cursor)
        end
    end
  end

  @doc "Default `handle_read_resource`: content-scheme URIs read off the mount, else static dispatch."
  # ⟦𓆒⟧ read_resource
  def read_resource(server, resources, templates, uri, ctx) do
    case resolve_uri(server, uri, ctx) do
      nil ->
        Resources.dispatch_read(resources, templates, uri, ctx)

      {backend, opts, vfs_path} ->
        # Same success shape as `Resources.dispatch_read/4`: the contents list.
        case VFS.read(backend, vfs_path, opts_ctx(ctx, opts)) do
          {:ok, content, _version} ->
            [
              ResourceContents.text(uri, content,
                mime_type: mime_type(backend, vfs_path, opts)
              )
            ]

          {:error, %Error{}} = error ->
            error

          {:error, errno} when is_atom(errno) ->
            {:error, VFS.errno_error(errno)}

          {:error, other} ->
            {:error, Error.internal("content read failed: #{inspect(other)}")}
        end
    end
  end

  @doc "Subscribe check: content-scheme resource URIs are subscribable (writes fan `notify_resource_updated/1`). `:pass` falls through to the static registry check."
  # ⟦𓆒⟧ check_subscribe
  def check_subscribe(server, uri, ctx) do
    case resolve_uri(server, uri, ctx, :resources) do
      {_backend, _opts, _path} -> :ok
      nil -> :pass
    end
  end

  # Every file under every resources prefix, depth-first.
  defp dynamic_resources(server, ctx) do
    Enum.flat_map(configs(server), fn {backend, opts} ->
      case opts[:resources] do
        nil ->
          []

        prefix ->
          prefix = norm(prefix)

          Enum.map(walk_files(backend, prefix, ctx, opts), fn path ->
            %Types.Resource{
              uri: dynamic_uri(opts, path),
              name: Path.basename(path),
              mime_type: mime_type(backend, path, opts),
              description: describe(backend, path, ctx, opts),
              size: stat_size(backend, path, ctx, opts)
            }
          end)
      end
    end)
  end

  # Every file under `root`, depth-first (directories recurse, files collect).
  defp walk_files(backend, root, ctx, opts) do
    case VFS.list(backend, root, nil, opts_ctx(ctx, opts)) do
      {:ok, entries, _next} ->
        Enum.flat_map(entries, fn entry ->
          child = join(root, entry.name)

          case entry.type do
            :dir -> walk_files(backend, child, ctx, opts)
            :file -> [child]
            _ -> []
          end
        end)

      {:error, _} ->
        # A missing/unreadable prefix advertises nothing rather than failing
        # the whole listing.
        []
    end
  end

  # `content://rel` → the vfs path under the covering prefix. Resources
  # prefixes are tried before prompts; each candidate must stat to a file.
  defp resolve_uri(server, uri, ctx, only \\ nil) do
    Enum.find_value(configs(server), fn {backend, opts} ->
      scheme = "#{opts[:uri_scheme] || "content"}://"

      with rel when is_binary(rel) <- trim_scheme(uri, scheme),
           prefixes = candidate_prefixes(opts, only) do
        Enum.find_value(prefixes, fn prefix ->
          path = join(norm(prefix), rel)

          case VFS.stat(backend, path, opts_ctx(ctx, opts)) do
            {:ok, %Noizu.MCP.VFS{type: :file}} -> {backend, opts, path}
            _ -> nil
          end
        end)
      else
        _ -> nil
      end
    end)
  end

  defp trim_scheme(uri, scheme) do
    if String.starts_with?(uri, scheme), do: String.trim_leading(uri, scheme), else: nil
  end

  defp candidate_prefixes(opts, nil), do: Enum.reject([opts[:resources], opts[:prompts]], &is_nil/1)
  defp candidate_prefixes(opts, key), do: if(opts[key], do: [opts[key]], else: [])

  @doc "The `content://` URI for a vfs path under a registration's resources prefix."
  # ⟦𓆒⟧ dynamic_uri
  def dynamic_uri(opts, vfs_path) do
    scheme = opts[:uri_scheme] || "content"
    prefix = norm(opts[:resources])
    rel = vfs_path |> String.trim_leading(prefix) |> String.trim_leading("/")
    "#{scheme}://#{rel}"
  end

  defp mime_type(backend, path, opts) do
    if function_exported?(backend, :mime_type, 2) do
      backend.mime_type(path, opts)
    else
      Map.get(@default_mime_types, path |> Path.extname() |> String.downcase(), "application/octet-stream")
    end
  end

  # First paragraph of text content; otherwise an xattr-provided description.
  defp describe(backend, path, ctx, opts) do
    mime = mime_type(backend, path, opts)

    with {:ok, content, _version} <- VFS.read(backend, path, opts_ctx(ctx, opts)),
         true <- String.starts_with?(mime || "", "text/") do
      content
      |> String.split("\n\n")
      |> List.first("")
      |> String.replace("\n", " ")
      |> String.trim()
    else
      _ ->
        case VFS.xattr(backend, path, opts_ctx(ctx, opts)) do
          {:ok, %{"description" => d}} when is_binary(d) -> d
          _ -> ""
        end
    end
  end

  defp stat_size(backend, path, ctx, opts) do
    case VFS.stat(backend, path, opts_ctx(ctx, opts)) do
      {:ok, node} -> node.size
      {:error, _} -> nil
    end
  end

  defp join(prefix, name), do: String.trim_trailing(prefix, "/") <> "/" <> name

  # ── prompts ───────────────────────────────────────────────────────────────

  @doc "Default `handle_list_prompts` over static registrations + content mounts."
  # ⟦𓆒⟧ list_prompts
  def list_prompts(server, prompts, cursor, ctx) do
    case dynamic_prompts(server, ctx) do
      [] ->
        Prompts.list_registered(prompts, cursor)

      dynamic ->
        with {:ok, static, _next} <- Prompts.list_registered(prompts, nil) do
          Pagination.paginate(static ++ dynamic, cursor)
        end
    end
  end

  @doc "Default `handle_get_prompt`: static dispatch first, then content-mount JSON prompts."
  # ⟦𓆒⟧ get_prompt
  def get_prompt(server, prompts, name, args, ctx) do
    case Prompts.find(prompts, name) do
      {_module, _opts} ->
        Prompts.dispatch_get(prompts, name, args, ctx)

      nil ->
        dynamic_get(server, name, args, ctx)
    end
  end

  defp dynamic_get(server, name, args, ctx) do
    case find_dynamic_prompt(server, name, ctx) do
      nil ->
        {:error, Error.invalid_params("Unknown prompt: #{name}")}

      {backend, opts, path} ->
        case VFS.read(backend, path, opts_ctx(ctx, opts)) do
          {:ok, raw, _version} ->
            with {:ok, json} <- decode_prompt(raw, path) do
              render_prompt(json, args)
            end

          {:error, %Error{}} = error ->
            error

          {:error, errno} when is_atom(errno) ->
            {:error, VFS.errno_error(errno)}

          {:error, other} ->
            {:error, Error.internal("content read failed: #{inspect(other)}")}
        end
    end
  end

  # A dynamic prompt is addressed by its file's stem; a JSON `name` field
  # that differs from the stem also resolves.
  defp find_dynamic_prompt(server, name, ctx) do
    Enum.find_value(configs(server), fn {backend, opts} ->
      opts[:prompts] &&
        walk_files(backend, norm(opts[:prompts]), ctx, opts)
        |> Enum.find_value(fn path ->
          cond do
            Path.basename(path, Path.extname(path)) == name ->
              {backend, opts, path}

            json_name(path, backend, ctx, opts) == name ->
              {backend, opts, path}

            true ->
              nil
          end
        end)
    end)
  end

  defp json_name(path, backend, ctx, opts) do
    case VFS.read(backend, path, opts_ctx(ctx, opts)) do
      {:ok, raw, _v} ->
        case Jason.decode(raw) do
          {:ok, %{"name" => name}} when is_binary(name) -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Files that fail to parse are skipped on listing (one broken file must not
  # hide the others); the error surfaces on `prompts/get`.
  defp dynamic_prompts(server, ctx) do
    Enum.flat_map(configs(server), fn {backend, opts} ->
      case opts[:prompts] do
        nil ->
          []

        prefix ->
          walk_files(backend, norm(prefix), ctx, opts)
          |> Enum.flat_map(fn path ->
            with {:ok, raw, _v} <- VFS.read(backend, path, opts_ctx(ctx, opts)),
                 {:ok, json} <- Jason.decode(raw),
                 true <- is_map(json) do
              [%Types.Prompt{
                 name: json["name"] || Path.basename(path, Path.extname(path)),
                 description: json["description"],
                 arguments:
                   Enum.map(json["arguments"] || [], fn argument ->
                     Prompt.Argument.from_map(argument || %{})
                   end)
               }]
            else
              _ -> []
            end
          end)
      end
    end)
  end

  defp decode_prompt(raw, path) do
    case Jason.decode(raw) do
      {:ok, %{} = json} ->
        {:ok, json}

      {:error, reason} ->
        {:error, Error.internal("invalid prompt JSON in #{path}: #{inspect(reason)}")}
    end
  end

  defp render_prompt(json, args) do
    declared = json["arguments"] || []

    missing =
      for argument <- declared,
          is_map(argument) and argument["required"] == true,
          not Map.has_key?(args, argument["name"]),
          do: argument["name"]

    case missing do
      [] ->
        messages =
          for %{"role" => role, "content" => content} <- json["messages"] || [] do
            %Types.PromptMessage{role: role_atom(role), content: render_content(content, args)}
          end

        {:ok, messages, description: json["description"]}

      missing ->
        {:error, Error.invalid_params("Missing required arguments: #{Enum.join(missing, ", ")}")}
    end
  end

  defp role_atom("user"), do: :user
  defp role_atom("assistant"), do: :assistant

  defp render_content(content, args) when is_binary(content),
    do: Types.Content.text(substitute(content, args))

  defp render_content(%{} = content, _args), do: Types.Content.from_map(content)

  # `{{argument}}` placeholders swap in the request's string-keyed arguments;
  # an argument that was not supplied keeps its placeholder.
  defp substitute(text, args) do
    Regex.replace(@placeholder, text, fn _whole, key ->
      case fetch_arg(args, key) do
        value when is_binary(value) -> value
        value when is_integer(value) -> Integer.to_string(value)
        _ -> "{{#{key}}}"
      end
    end)
  end

  defp fetch_arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(args, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end
end
