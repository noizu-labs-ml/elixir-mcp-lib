defmodule Noizu.MCP.Sync.Protocol do
  @moduledoc "Validation and explicit dispatch for the opt-in sync/version 1 contract."
  alias Noizu.MCP.Error

  @methods %{
    "sync/capabilities" => :capabilities,
    "sync/snapshot" => :snapshot,
    "sync/changes" => :changes,
    "sync/mutate" => :mutate,
    "sync/operation" => :operation
  }

  @doc "Dispatches a validated request to a trusted, principal-bound Source."
  def dispatch({module, state}, method, params) when is_atom(module) do
    with :ok <- validate(method, params) do
      case apply(module, Map.fetch!(@methods, method), [params, state]) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, %Error{}} = error -> error
        _ -> {:error, error("invalid_response")}
      end
    end
  end

  @doc "Validates the wire envelope without resolving identity from caller input."
  def validate(method, params) do
    cond do
      not Map.has_key?(@methods, method) ->
        {:error, Error.method_not_found(method)}

      not is_map(params) ->
        {:error, error("invalid_request")}

      Enum.any?(Map.keys(params), &(&1 not in allowed_fields(method))) ->
        {:error, error("invalid_request")}

      not nonempty?(params["relation"]) ->
        {:error, error("invalid_request")}

      Enum.any?(
        ~w(bindingId binding_id credentials credential_ref repo principal tenant),
        &Map.has_key?(params, &1)
      ) ->
        {:error, error("invalid_request")}

      method == "sync/mutate" ->
        validate_mutation(params)

      method == "sync/operation" and not nonempty?(params["operationId"]) ->
        {:error, error("invalid_request")}

      method == "sync/changes" and not is_binary(params["cursor"]) ->
        {:error, error("invalid_request")}

      method in ["sync/snapshot", "sync/changes"] ->
        validate_page(params)

      true ->
        :ok
    end
  end

  @doc "Refuses writable bindings unless all consistency guarantees are explicit."
  def writable(%{
        "version" => 1,
        "snapshot" => "consistent",
        "changes" => true,
        "conditionalWrites" => true,
        "idempotency" => true,
        "idempotencyRetentionSeconds" => retention,
        "changeRetentionSeconds" => changes
      })
      when is_integer(retention) and retention > 0 and is_integer(changes) and changes > 0,
      do: :ok

  def writable(_), do: {:error, error("unsupported_consistency")}

  @doc "Builds a stable protocol error without database internals or credentials."
  def error(code, evidence \\ %{}) do
    Error.custom(-32_010, "Synchronization request failed", Map.put(evidence, "syncCode", code))
  end

  defp allowed_fields("sync/capabilities"), do: ~w(relation)
  defp allowed_fields("sync/snapshot"), do: ~w(relation snapshotCursor limit)
  defp allowed_fields("sync/changes"), do: ~w(relation cursor limit)

  defp allowed_fields("sync/mutate"),
    do: ~w(relation key operationId operation precondition value)

  defp allowed_fields("sync/operation"), do: ~w(relation operationId)

  defp validate_page(params) do
    limit = params["limit"] || 500
    cursor = params["snapshotCursor"]

    if is_integer(limit) and limit > 0 and limit <= 500 and (is_nil(cursor) or is_binary(cursor)),
      do: :ok,
      else: {:error, error("invalid_request")}
  end

  defp validate_mutation(params) do
    valid_precondition =
      case {params["operation"], params["precondition"]} do
        {"create", %{"absent" => true} = pre} ->
          map_size(pre) == 1

        {op, %{"revision" => revision} = pre} when op in ["update", "delete"] ->
          nonempty?(revision) and map_size(pre) == 1

        _ ->
          false
      end

    valid_value = params["operation"] == "delete" or is_map(params["value"])

    if is_map(params["key"]) and map_size(params["key"]) > 0 and nonempty?(params["operationId"]) and
         valid_precondition and valid_value, do: :ok, else: {:error, error("invalid_request")}
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
end
