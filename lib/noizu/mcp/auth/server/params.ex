defmodule Noizu.MCP.Auth.Server.Params do
  @moduledoc """
  Parameter extraction for the OAuth endpoints.

  Plug hands over `%{"key" => value}` where a value may be a binary, a **list**
  (the parameter was sent twice), or a nested map (`key[sub]=…`). Only a single
  binary is ever a valid OAuth parameter, so anything else is rejected rather
  than coerced — `?scope=mcp&scope=admin` picking one arm is how two halves of
  a server disagree about what was requested.

  Every failure is a `Noizu.MCP.Auth.Server.Errors` struct, so the caller can
  render it without composing a message of its own (and therefore without
  reflecting input).

      iex> Noizu.MCP.Auth.Server.Params.fetch(%{"client_id" => "abc"}, "client_id")
      {:ok, "abc"}

      iex> {:error, error} = Noizu.MCP.Auth.Server.Params.fetch(%{"a" => ["1", "2"]}, "a")
      iex> error.code
      :invalid_request
  """

  alias Noizu.MCP.Auth.Server.Errors

  # Long enough for a 128-char PKCE verifier, a JWT client assertion, or a
  # registration redirect URI; short enough that nothing unbounded is copied
  # into a log line or a database column.
  @max_value 4_096

  @doc """
  Fetch a required single-valued parameter.

  Options: `:code` (error code on failure, default `:invalid_request`),
  `:max` (length cap, default `#{@max_value}`).
  """
  @spec fetch(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Errors.t()}
  def fetch(params, key, opts \\ []) do
    case optional(params, key, opts) do
      {:ok, nil} -> {:error, error(opts, {:missing, key})}
      {:ok, value} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  @doc """
  Fetch an optional single-valued parameter as `{:ok, value | nil}`.

  A present-but-blank value reads as absent: `?state=` is a client that built
  the query carelessly, not a client asserting the empty string.
  """
  @spec optional(map(), String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, Errors.t()}
  def optional(params, key, opts \\ []) do
    max = Keyword.get(opts, :max, @max_value)

    case Map.get(params, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) and byte_size(value) > max -> {:error, error(opts, {:too_long, key})}
      value when is_binary(value) -> {:ok, value}
      # A list means the parameter was repeated; a map means it was sent in
      # bracket form. Neither is a valid OAuth parameter.
      _other -> {:error, error(opts, {:not_single, key})}
    end
  end

  @doc """
  Fetch several required parameters at once, returning a map keyed by the same
  strings. Fails on the first missing one.
  """
  @spec fetch_all(map(), [String.t()], keyword()) :: {:ok, map()} | {:error, Errors.t()}
  def fetch_all(params, keys, opts \\ []) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case fetch(params, key, opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Parse a space-delimited list parameter (`scope`, `response_type`) into a
  deduplicated list, preserving order. Absent → `[]`.
  """
  @spec space_list(map(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, Errors.t()}
  def space_list(params, key, opts \\ []) do
    with {:ok, value} <- optional(params, key, opts) do
      case value do
        nil -> {:ok, []}
        value -> {:ok, value |> String.split(" ", trim: true) |> Enum.uniq()}
      end
    end
  end

  @doc """
  Check a value against an allowlist of permitted values.

  The value is never echoed in the error — the caller only learns that what it
  sent is not on the list.
  """
  @spec allowed(String.t(), [String.t()], keyword()) :: :ok | {:error, Errors.t()}
  def allowed(value, allowlist, opts \\ []) do
    if value in allowlist, do: :ok, else: {:error, error(opts, {:not_allowed, value})}
  end

  @doc """
  Require every requested scope to be within what the server (or client) may
  grant. Returns the requested scopes, or `invalid_scope`.
  """
  @spec within_scope([String.t()], [String.t()]) :: {:ok, [String.t()]} | {:error, Errors.t()}
  def within_scope(requested, permitted) do
    case Enum.reject(requested, &(&1 in permitted)) do
      [] -> {:ok, requested}
      _rejected -> {:error, Errors.new(:invalid_scope, reason: :scope_exceeds_permitted)}
    end
  end

  @doc """
  Extract HTTP Basic client credentials from an `authorization` header value.

  `{:ok, {client_id, secret}}`, `{:ok, nil}` when the header is absent or not
  Basic, or `invalid_client` when it is Basic but unparseable. Per RFC 6749
  §2.3.1 both halves are form-urlencoded inside the credential.
  """
  @spec basic_credentials(String.t() | nil) ::
          {:ok, {String.t(), String.t()} | nil} | {:error, Errors.t()}
  def basic_credentials(nil), do: {:ok, nil}

  def basic_credentials(header) when is_binary(header) do
    case header do
      "Basic " <> encoded -> decode_basic(encoded)
      "basic " <> encoded -> decode_basic(encoded)
      _ -> {:ok, nil}
    end
  end

  defp decode_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [client_id, secret] <- String.split(decoded, ":", parts: 2) do
      {:ok, {URI.decode_www_form(client_id), URI.decode_www_form(secret)}}
    else
      _ -> {:error, Errors.new(:invalid_client, reason: :malformed_basic_credentials)}
    end
  end

  defp error(opts, reason),
    do: Errors.new(Keyword.get(opts, :code, :invalid_request), reason: reason)
end
