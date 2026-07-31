defmodule Noizu.MCP.Auth.Server.Errors do
  @moduledoc """
  OAuth error codes and rendering (RFC 6749 §4.1.2.1/§5.2, RFC 7591 §3.2.2,
  RFC 8707 §2, RFC 6750 §3.1).

  ## `error_description` never reflects input

  Every description here is a fixed string chosen by the code, keyed off the
  error code. Nothing a client sent is echoed into a response body or a redirect
  query. That closes two things at once: reflected XSS on the rendered error
  page a browser will see, and the oracle where a description tells an attacker
  which of several checks their probe tripped.

  When more detail is genuinely needed, it goes to the log with a correlation id
  — `annotate/2` carries a private reason that renders nowhere.

      iex> Noizu.MCP.Auth.Server.Errors.new(:invalid_grant) |> Noizu.MCP.Auth.Server.Errors.to_map()
      %{"error" => "invalid_grant", "error_description" => "The grant is invalid, expired, or has already been used."}
  """

  @type code ::
          :invalid_request
          | :invalid_client
          | :invalid_grant
          | :unauthorized_client
          | :unsupported_grant_type
          | :unsupported_response_type
          | :invalid_scope
          | :invalid_target
          | :access_denied
          | :server_error
          | :temporarily_unavailable
          | :invalid_redirect_uri
          | :invalid_client_metadata
          | :invalid_token
          | :insufficient_scope
          | :login_required
          | :consent_required
          | :interaction_required

  @type t :: %__MODULE__{
          code: code(),
          status: 200..599,
          state: String.t() | nil,
          reason: term()
        }

  defstruct code: :server_error, status: 500, state: nil, reason: nil

  # {description, http status}. Descriptions are deliberately generic.
  @catalog %{
    invalid_request:
      {"The request is missing a required parameter or is otherwise malformed.", 400},
    invalid_client: {"Client authentication failed.", 401},
    invalid_grant: {"The grant is invalid, expired, or has already been used.", 400},
    unauthorized_client: {"This client is not authorized to use this grant type.", 400},
    unsupported_grant_type: {"The grant type is not supported by this server.", 400},
    unsupported_response_type: {"The response type is not supported by this server.", 400},
    invalid_scope: {"The requested scope is invalid or exceeds what may be granted.", 400},
    invalid_target: {"The requested resource is unknown or not permitted for this client.", 400},
    access_denied: {"The request was denied.", 403},
    server_error: {"The server encountered an unexpected condition.", 500},
    temporarily_unavailable: {"The server is temporarily unable to handle the request.", 503},
    invalid_redirect_uri: {"The redirect URI is missing or not permitted for this client.", 400},
    invalid_client_metadata: {"The client metadata is invalid.", 400},
    invalid_token: {"The access token is invalid or expired.", 401},
    insufficient_scope: {"The access token does not carry the required scope.", 403},
    login_required: {"End-user authentication is required.", 401},
    consent_required: {"End-user consent is required.", 401},
    interaction_required: {"End-user interaction is required.", 401}
  }

  @doc """
  Build an error. An unrecognized code becomes `:server_error` — a code that is
  not in the catalog is a bug here, not something to render verbatim.

  Options: `:state` (echoed back on a redirect response, per RFC 6749),
  `:status` (override), `:reason` (private, logged never rendered).
  """
  @spec new(code() | String.t(), keyword()) :: t()
  def new(code, opts \\ []) do
    code = normalize_code(code)
    {_description, default_status} = Map.fetch!(@catalog, code)

    %__MODULE__{
      code: code,
      status: Keyword.get(opts, :status, default_status),
      state: Keyword.get(opts, :state),
      reason: Keyword.get(opts, :reason)
    }
  end

  @doc "Attach a private reason for logging. Never rendered."
  @spec annotate(t(), term()) :: t()
  def annotate(%__MODULE__{} = error, reason), do: %{error | reason: reason}

  @doc "Attach the `state` to echo on a redirect error response."
  @spec with_state(t(), String.t() | nil) :: t()
  def with_state(%__MODULE__{} = error, state), do: %{error | state: state}

  @doc "Every code this module renders."
  @spec codes() :: [code()]
  def codes, do: Map.keys(@catalog)

  @doc "The canned description for a code."
  @spec description(t() | code()) :: String.t()
  def description(%__MODULE__{code: code}), do: description(code)

  def description(code) do
    {description, _status} = Map.fetch!(@catalog, normalize_code(code))
    description
  end

  @doc "HTTP status for an error."
  @spec status(t() | code()) :: 200..599
  def status(%__MODULE__{status: status}), do: status

  def status(code) do
    {_description, status} = Map.fetch!(@catalog, normalize_code(code))
    status
  end

  @doc "JSON body for a token/registration/revocation error response."
  @spec to_map(t() | code()) :: %{required(String.t()) => String.t()}
  def to_map(%__MODULE__{} = error) do
    %{"error" => to_string(error.code), "error_description" => description(error)}
    |> maybe_put("state", error.state)
  end

  def to_map(code), do: to_map(new(code))

  @doc "URL-encoded query fragment for a redirect error response."
  @spec to_query(t() | code()) :: String.t()
  def to_query(error), do: error |> to_map() |> URI.encode_query()

  @doc """
  Append an error to a redirect URI's query.

  Only ever called with a `redirect_uri` that already passed
  `Noizu.MCP.Auth.Server.RedirectURI` validation against the resolved client —
  an unresolved client or an unvalidated URI must be rendered, never redirected
  to, or the authorization endpoint becomes an open redirector.
  """
  @spec redirect_url(String.t(), t()) :: String.t()
  def redirect_url(redirect_uri, %__MODULE__{} = error) do
    uri = URI.parse(redirect_uri)
    query = [uri.query, to_query(error)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("&")

    URI.to_string(%{uri | query: query})
  end

  defp normalize_code(code) when is_atom(code) do
    if Map.has_key?(@catalog, code), do: code, else: :server_error
  end

  defp normalize_code(code) when is_binary(code) do
    # `String.to_existing_atom/1` on request-supplied text is an atom-table
    # probe; match against the known set instead.
    Enum.find(Map.keys(@catalog), :server_error, &(to_string(&1) == code))
  end

  defp normalize_code(_code), do: :server_error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
