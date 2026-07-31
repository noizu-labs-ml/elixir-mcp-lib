if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.ProtectedResourceMetadataPlug do
    @moduledoc """
    Serves the RFC 9728 protected-resource metadata document MCP clients use
    to discover your authorization server:

        # Phoenix router (path is fixed by RFC 9728)
        forward "/.well-known/oauth-protected-resource",
                Noizu.MCP.Auth.ProtectedResourceMetadataPlug,
                resource: "https://api.example.com/mcp",
                authorization_servers: ["https://auth.example.com"]

    Options: `:resource` (required), `:authorization_servers` (required),
    `:scopes_supported`, `:bearer_methods_supported`, `:resource_name`,
    `:extra` (map merged in).

    ## Several mounts behind one forward

    A host with more than one MCP mount needs a *distinct* `resource` value per
    mount, and RFC 9728 path-insertion puts the mount path in the well-known
    URL: `/.well-known/oauth-protected-resource/mcp/learning` describes
    `https://host/mcp/learning`. Pass `:resources` — a map of path suffix to
    per-resource options — and one forward answers them all:

        forward "/.well-known/oauth-protected-resource",
                Noizu.MCP.Auth.ProtectedResourceMetadataPlug,
                authorization_servers: ["https://app.example.com"],
                scopes_supported: ["mcp"],
                default_resource: "/mcp",
                resources: %{
                  "/mcp" => [resource: "https://app.example.com/mcp"],
                  "/mcp/learning" => [resource: "https://app.example.com/mcp/learning"],
                  "/mcp/workspace" => [resource: "https://app.example.com/mcp/workspace"]
                }

    Top-level options are defaults every entry inherits; entry options win.
    `:default_resource` names the suffix answered at the bare forward path
    (what a client that skipped path-insertion asks for). An unknown suffix is
    a **404** — never a document describing some other resource, which would
    hand a client the wrong audience.

    ## CORS

    claude.ai performs discovery from a browser context, so the document is
    served with `Access-Control-Allow-Origin` (default `*` — it is public,
    unauthenticated metadata) and `OPTIONS` answers `204`. Pass
    `allow_origin: nil` to omit the header.
    """

    @behaviour Plug
    import Plug.Conn

    @allow_headers "authorization, content-type, mcp-protocol-version"

    @impl Plug
    # ⟦𓇰𓏽𓆆𓇚⟧ init :: auto-generated pointer for public function init
    def init(opts) do
      %{
        documents: documents(opts),
        default: normalize_suffix(Keyword.get(opts, :default_resource)),
        allow_origin: Keyword.get(opts, :allow_origin, "*")
      }
    end

    @impl Plug
    # ⟦𓎅𓋅𓆙𓐇⟧ call :: auto-generated pointer for public function call
    def call(%{method: "OPTIONS"} = conn, opts) do
      conn
      |> cors_headers(opts)
      |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
      |> put_resp_header("access-control-allow-headers", @allow_headers)
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
    end

    def call(%{method: "GET"} = conn, opts) do
      case lookup(opts, conn.path_info) do
        {:ok, body} ->
          conn
          |> cors_headers(opts)
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        :error ->
          conn
          |> cors_headers(opts)
          |> put_resp_content_type("application/json")
          |> send_resp(404, ~s({"error":"not_found"}))
      end
    end

    def call(conn, _opts), do: send_resp(conn, 405, "Method not allowed")

    # ── documents ────────────────────────────────────────────────────────────

    defp documents(opts) do
      case Keyword.get(opts, :resources) do
        nil ->
          # Single-resource mode: one document, served at any suffix (a client
          # that path-inserts a mount this host has only one of still works).
          %{:any => document(opts)}

        resources when is_map(resources) or is_list(resources) ->
          defaults = Keyword.drop(opts, [:resources, :default_resource, :allow_origin])

          Map.new(resources, fn {suffix, resource_opts} ->
            {normalize_suffix(suffix), document(Keyword.merge(defaults, to_opts(resource_opts)))}
          end)
      end
    end

    defp document(opts) do
      %{
        "resource" => Keyword.fetch!(opts, :resource),
        "authorization_servers" => Keyword.fetch!(opts, :authorization_servers)
      }
      |> put_opt(opts, :scopes_supported, "scopes_supported")
      |> put_opt(opts, :bearer_methods_supported, "bearer_methods_supported")
      |> put_opt(opts, :resource_name, "resource_name")
      |> Map.merge(Keyword.get(opts, :extra, %{}))
      |> Jason.encode!()
    end

    defp to_opts(opts) when is_list(opts), do: opts
    defp to_opts(opts) when is_map(opts), do: Enum.into(opts, [])

    defp lookup(%{documents: %{any: body}}, _path_info), do: {:ok, body}

    defp lookup(opts, path_info) do
      suffix = Enum.map_join(path_info, "/", & &1)
      suffix = if suffix == "", do: opts.default, else: suffix

      case Map.fetch(opts.documents, suffix) do
        {:ok, body} -> {:ok, body}
        :error -> :error
      end
    end

    defp normalize_suffix(nil), do: nil
    defp normalize_suffix(suffix) when is_list(suffix), do: Enum.join(suffix, "/")

    defp normalize_suffix(suffix) when is_binary(suffix),
      do: suffix |> String.trim("/") |> String.trim()

    defp cors_headers(conn, %{allow_origin: nil}), do: conn

    defp cors_headers(conn, %{allow_origin: origin}) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("vary", "origin")
    end

    defp put_opt(document, opts, key, json_key) do
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(document, json_key, value)
        :error -> document
      end
    end
  end
end
