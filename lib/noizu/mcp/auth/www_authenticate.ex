defmodule Noizu.MCP.Auth.WWWAuthenticate do
  @moduledoc """
  Parse and format `WWW-Authenticate` challenges (RFC 9110 §11.6.1), as used
  by the MCP authorization spec to point clients at protected-resource
  metadata and signal `insufficient_scope` step-up.
  """

  @type t :: %__MODULE__{scheme: String.t(), params: %{optional(String.t()) => String.t()}}
  defstruct scheme: "Bearer", params: %{}

  @doc ~S"""
  Parse a challenge header value.

      iex> Noizu.MCP.Auth.WWWAuthenticate.parse(
      ...>   ~s(Bearer resource_metadata="https://x/.well-known/oauth-protected-resource", error="invalid_token")
      ...> )
      %Noizu.MCP.Auth.WWWAuthenticate{
        scheme: "Bearer",
        params: %{
          "resource_metadata" => "https://x/.well-known/oauth-protected-resource",
          "error" => "invalid_token"
        }
      }
  """
  @spec parse(String.t() | nil) :: t() | nil
  # ⟦𓐕𓁘𓉸𓁐⟧ parse :: auto-generated pointer for public function parse
  def parse(nil), do: nil

  def parse(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme] ->
        %__MODULE__{scheme: scheme}

      [scheme, params] ->
        parsed =
          ~r/([a-zA-Z0-9_]+)=(?:"([^"]*)"|([^,\s]+))/
          |> Regex.scan(params)
          |> Map.new(fn
            [_, key, quoted] -> {key, quoted}
            [_, key, "", bare] -> {key, bare}
          end)

        %__MODULE__{scheme: scheme, params: parsed}
    end
  end

  @doc """
  Format a challenge header value. `params` is an enumerable of name/value
  pairs; values are escaped with `escape_quoted/1`, so a value carrying CR/LF
  raises rather than splitting the response header.
  """
  @spec format(String.t(), [{String.t() | atom(), String.t()}] | map()) :: String.t()
  # ⟦𓆺𓋁𓄴𓈞⟧ format :: Format a challenge header value.
  def format(scheme \\ "Bearer", params) do
    rendered =
      Enum.map_join(params, ", ", fn {key, value} ->
        ~s(#{validate_token!(key)}="#{escape_quoted(value)}")
      end)

    case rendered do
      "" -> scheme
      rendered -> "#{scheme} #{rendered}"
    end
  end

  @doc ~S"""
  Build a `Bearer` challenge from a keyword list, dropping `nil` values.

  Ordering is preserved, so callers control how the challenge reads:

      iex> Noizu.MCP.Auth.WWWAuthenticate.bearer_challenge(
      ...>   resource_metadata: "https://x/.well-known/oauth-protected-resource",
      ...>   scope: nil,
      ...>   error: "invalid_token"
      ...> )
      ~s(Bearer resource_metadata="https://x/.well-known/oauth-protected-resource", error="invalid_token")
  """
  @spec bearer_challenge([{String.t() | atom(), String.t() | nil}] | map()) :: String.t()
  def bearer_challenge(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> then(&format("Bearer", &1))
  end

  @doc ~S"""
  Escape a value for a `quoted-string` (RFC 9110 §5.6.4).

  Backslash and double quote are escaped. CR, LF, NUL and any other control
  character are **rejected** — they cannot be represented in a quoted-string
  and are the header-injection vector — so this raises `ArgumentError` rather
  than emitting a header an attacker chose the shape of. The raised message
  never includes the offending value.

      iex> Noizu.MCP.Auth.WWWAuthenticate.escape_quoted(~s(a"b\\c))
      ~S(a\"b\\c)
  """
  @spec escape_quoted(String.t() | atom() | number()) :: String.t()
  def escape_quoted(value) when is_atom(value) or is_number(value),
    do: escape_quoted(to_string(value))

  def escape_quoted(value) when is_binary(value) do
    if printable_field_value?(value) do
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
    else
      raise ArgumentError,
            "WWW-Authenticate parameter value contains a control character " <>
              "(CR, LF, NUL, DEL or other) and cannot be encoded safely"
    end
  end

  # RFC 9110 qdtext/quoted-pair: HTAB, SP, VCHAR and obs-text only.
  defp printable_field_value?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 == 0x09 or (&1 >= 0x20 and &1 != 0x7F)))
  end

  defp validate_token!(key) do
    key = to_string(key)

    if Regex.match?(~r/\A[A-Za-z0-9!#$%&'*+\-.^_`|~]+\z/, key) do
      key
    else
      raise ArgumentError, "WWW-Authenticate parameter name is not a valid HTTP token"
    end
  end
end
