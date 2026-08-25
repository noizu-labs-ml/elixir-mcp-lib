defmodule Noizu.MCP.Client.Telemetry do
  @moduledoc """
  Telemetry events emitted by `Noizu.MCP.Client`.

  Every outbound request emits a request span using `:start`, `:stop`, or
  `:exception` under `[:noizu_mcp, :client, :request, ...]`. Tool calls and
  discovery requests mirror those stages under `:tool` and `:discovery`.
  Transport failures emit `[:noizu_mcp, :client, :transport, :exception]`.

  Start measurements contain `:system_time`; stop and request-exception
  measurements contain native-unit `:duration`. Metadata contains only safe
  routing, operation, status, and correlation fields. Request arguments,
  results, headers, authentication material, and raw error reasons are never
  included.
  """

  @request_events for stage <- [:start, :stop, :exception],
                      do: [:noizu_mcp, :client, :request, stage]
  @tool_events for stage <- [:start, :stop, :exception],
                   do: [:noizu_mcp, :client, :tool, stage]
  @discovery_events for stage <- [:start, :stop, :exception],
                        do: [:noizu_mcp, :client, :discovery, stage]
  @transport_events [[:noizu_mcp, :client, :transport, :exception]]
  @correlation_keys [:correlation_id, :trace_id, :span_id, :chain_id, :run_id]

  @doc "All client event names, suitable for `:telemetry.attach_many/4`."
  @spec events() :: [[atom()]]
  def events, do: @request_events ++ @tool_events ++ @discovery_events ++ @transport_events

  @doc "Keys accepted from the per-request `:telemetry_metadata` option."
  @spec correlation_keys() :: [atom()]
  def correlation_keys, do: @correlation_keys

  @doc false
  def correlation(opts) do
    metadata = Keyword.get(opts, :telemetry_metadata, %{})

    if is_map(metadata) or Keyword.keyword?(metadata) do
      metadata
      |> Map.new()
      |> Map.take(@correlation_keys)
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_binary(value) or is_integer(value) or is_atom(value) ->
          Map.put(acc, key, value)

        _entry, acc ->
          acc
      end)
    else
      %{}
    end
  end

  @doc false
  def emit(stage, measurements, metadata) when stage in [:start, :stop, :exception] do
    :telemetry.execute([:noizu_mcp, :client, :request, stage], measurements, metadata)

    case metadata[:operation] do
      :tool ->
        :telemetry.execute([:noizu_mcp, :client, :tool, stage], measurements, metadata)

      :discovery ->
        :telemetry.execute([:noizu_mcp, :client, :discovery, stage], measurements, metadata)

      _ ->
        :ok
    end
  end

  @doc false
  def emit_transport(measurements, metadata) do
    :telemetry.execute([:noizu_mcp, :client, :transport, :exception], measurements, metadata)
  end
end
