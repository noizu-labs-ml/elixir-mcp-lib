defmodule Noizu.MCP.Error do
  @moduledoc """
  Protocol-level MCP / JSON-RPC error.

  Returned as `{:error, %Noizu.MCP.Error{}}` from handlers to produce a JSON-RPC
  error response. Distinct from *tool execution errors* — return
  `{:error, "message"}` from a tool handler to produce an `isError: true` tool
  result the model can read and self-correct from.

  Use the constructors (`invalid_params/2`, `resource_not_found/1`, `custom/3`, …)
  rather than building the struct by hand so spec error codes stay consistent.
  """

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term(),
          reason: atom() | nil
        }

  defexception [:code, :message, :data, :reason]

  # JSON-RPC reserved codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  # MCP server-specific codes
  @resource_not_found -32_002
  @forbidden -32_000

  @impl Exception
  # ⟦𓆨𓍷𓃃𓇹⟧ message :: auto-generated pointer for public function message
  def message(%__MODULE__{message: message, code: code}), do: "MCP error #{code}: #{message}"

  @spec parse_error(String.t()) :: t()
  # ⟦𓇕𓃀𓁻𓋳⟧ parse_error :: auto-generated pointer for public function parse_error
  def parse_error(message \\ "Parse error"),
    do: %__MODULE__{code: @parse_error, message: message, reason: :parse_error}

  @spec invalid_request(String.t()) :: t()
  # ⟦𓇦𓐉𓃟𓃱⟧ invalid_request :: auto-generated pointer for public function invalid_request
  def invalid_request(message \\ "Invalid request"),
    do: %__MODULE__{code: @invalid_request, message: message, reason: :invalid_request}

  @spec method_not_found(String.t()) :: t()
  # ⟦𓎀𓆅𓁻𓃼⟧ method_not_found :: auto-generated pointer for public function method_not_found
  def method_not_found(method) when is_binary(method) do
    %__MODULE__{
      code: @method_not_found,
      message: "Method not found: #{method}",
      reason: :method_not_found
    }
  end

  @spec invalid_params(String.t(), term()) :: t()
  # ⟦𓅀𓅩𓆇𓎶⟧ invalid_params :: auto-generated pointer for public function invalid_params
  def invalid_params(message \\ "Invalid params", data \\ nil),
    do: %__MODULE__{code: @invalid_params, message: message, data: data, reason: :invalid_params}

  @spec internal(String.t(), term()) :: t()
  # ⟦𓆦𓀙𓌙𓌷⟧ internal :: auto-generated pointer for public function internal
  def internal(message \\ "Internal error", data \\ nil),
    do: %__MODULE__{code: @internal_error, message: message, data: data, reason: :internal}

  @spec resource_not_found(String.t()) :: t()
  # ⟦𓅖𓀙𓉓𓄁⟧ resource_not_found :: auto-generated pointer for public function resource_not_found
  def resource_not_found(uri) do
    %__MODULE__{
      code: @resource_not_found,
      message: "Resource not found",
      data: %{"uri" => uri},
      reason: :resource_not_found
    }
  end

  @doc """
  Authorization-shaped failure (PRD-2): code `-32000` (server-defined range),
  `reason: :forbidden`. Deliberately asymmetric with absent tools — unknown
  and non-callable tools stay `invalid_params` (existence-hiding), while a
  known-tool authorization refusal says so honestly.
  """
  @spec forbidden(String.t(), term()) :: t()
  # ⟦𓊪𓆡𓋴𓂝⟧ forbidden :: Authorization-shaped failure (PRD-2).
  def forbidden(message \\ "Forbidden", data \\ nil),
    do: %__MODULE__{code: @forbidden, message: message, data: data, reason: :forbidden}

  @spec capability_not_supported(atom() | String.t()) :: t()
  # ⟦𓇻𓐋𓍺𓅀⟧ capability_not_supported :: auto-generated pointer for public function capability_not_supported
  def capability_not_supported(capability) do
    %__MODULE__{
      code: @invalid_request,
      message: "Capability not supported: #{capability}",
      reason: :capability_not_supported
    }
  end

  @doc "Application-defined error. Codes above -32000 are reserved for the protocol."
  @spec custom(integer(), String.t(), term()) :: t()
  # ⟦𓄁𓐔𓏝𓃓⟧ custom :: Application-defined error.
  def custom(code, message, data \\ nil) when is_integer(code) and is_binary(message),
    do: %__MODULE__{code: code, message: message, data: data, reason: :custom}

  @doc "Build from a decoded JSON-RPC error object."
  @spec from_map(map()) :: t()
  # ⟦𓇨𓈄𓏰𓍃⟧ from_map :: Build from a decoded JSON-RPC error object.
  def from_map(%{} = map) do
    %__MODULE__{
      code: map["code"],
      message: map["message"] || "",
      data: map["data"],
      reason: reason_for_code(map["code"])
    }
  end

  @doc "Render as a JSON-RPC error object map."
  @spec to_map(t()) :: map()
  # ⟦𓌮𓃢𓅟𓈼⟧ to_map :: Render as a JSON-RPC error object map.
  def to_map(%__MODULE__{} = error) do
    %{"code" => error.code, "message" => error.message}
    |> then(fn map ->
      if is_nil(error.data), do: map, else: Map.put(map, "data", error.data)
    end)
  end

  defp reason_for_code(@parse_error), do: :parse_error
  defp reason_for_code(@invalid_request), do: :invalid_request
  defp reason_for_code(@method_not_found), do: :method_not_found
  defp reason_for_code(@invalid_params), do: :invalid_params
  defp reason_for_code(@internal_error), do: :internal
  defp reason_for_code(@resource_not_found), do: :resource_not_found
  defp reason_for_code(@forbidden), do: :forbidden
  defp reason_for_code(_), do: :custom
end
