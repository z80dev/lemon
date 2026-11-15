defmodule LemonAgent.GenAISpans do
  @moduledoc """
  Optional GenAI span export for admitted model and tool calls.

  Disabled by default. Configure `:lemon_agent, :gen_ai_spans` with
  `enabled: true` and an `:exporter` implementing
  `LemonAgent.GenAISpans.Exporter`; `:exporter_config` is passed to it unchanged.
  The default exporter is `LemonAgent.GenAISpans.OpenTelemetry`, compiled only
  when the optional `opentelemetry_api` dependency is available. The host owns
  SDK startup, processors, sampling and transport configuration.

  A span is exported on each `:stop` or `:exception`, using the terminal native
  monotonic timestamp and duration. There is no per-call registry, pairing
  timeout or leaked open span when a producer is killed. Model streams may end
  in a different process; export does not depend on the process that started
  them. Calls killed without a terminal event cannot be exported.

  These are standalone spans, not a request trace hierarchy: no process-local
  parent is inferred from a stream tracker. The OTel adapter creates root spans
  without changing the caller's current context. Prompt/response content,
  tool arguments/results, raw exceptions, paths and credentials are never copied
  into attributes. There is deliberately no content-capture option.

  Model/tool `duration` and `monotonic_time` use native units. Other telemetry
  families retain their explicitly suffixed legacy units; see `docs/telemetry.md`.
  """

  use GenServer
  require Logger

  alias LemonAgent.GenAISpans.Exporter

  @events for prefix <- [[:lemon_ai, :model_call], [:lemon_agent, :tool_call]],
              suffix <- [:stop, :exception],
              do: prefix ++ [suffix]

  @doc "Returns the optional application children; missing `:enabled` means off."
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(config) do
    if Keyword.get(config, :enabled, false), do: [{__MODULE__, config}], else: []
  end

  @doc "Starts the supervised attachment explicitly, independently of app configuration."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    exporter = Keyword.get(opts, :exporter, __MODULE__.OpenTelemetry)

    with :ok <- LemonCore.Contract.validate(exporter, Exporter) do
      Process.flag(:trap_exit, true)
      config = {exporter, Keyword.get(opts, :exporter_config)}
      # A hard-killed attachment cannot run terminate/2. Reclaim its fixed id
      # on supervised restart rather than leaving a duplicate handler behind.
      :telemetry.detach(__MODULE__)
      :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, config)
      {:ok, config}
    else
      {:error, reason} -> {:stop, {:invalid_gen_ai_exporter, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  @doc false
  def handle_event(
        event,
        %{duration: duration, monotonic_time: ended_at} = measurements,
        metadata,
        config
      )
      when is_integer(duration) and duration >= 0 and is_integer(ended_at) do
    {name, kind, attributes, error?} = describe(event, metadata)

    attributes =
      if error?, do: Map.put(attributes, "error.type", error_type(event)), else: attributes

    attributes =
      if kind == :client do
        Enum.reduce(
          [
            {"gen_ai.usage.output_tokens", :output_tokens},
            {"gen_ai.usage.cache_read.input_tokens", :cache_read_tokens},
            {"gen_ai.usage.cache_write.input_tokens", :cache_write_tokens}
          ],
          attributes,
          fn {attribute, measurement}, acc ->
            case Map.get(measurements, measurement) do
              count when is_integer(count) and count >= 0 -> Map.put(acc, attribute, count)
              _ -> acc
            end
          end
        )
        |> total_input(measurements)
      else
        attributes
      end

    export(config, %{
      name: name,
      kind: kind,
      attributes: attributes,
      status: if(error?, do: :error, else: :unset),
      start_time: ended_at - duration,
      end_time: ended_at,
      duration: duration
    })
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp describe([:lemon_ai, :model_call, suffix], metadata) do
    model = label(Map.get(metadata, :model), "unknown")
    provider = label(Map.get(metadata, :provider), "unknown")

    attributes = %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.system" => provider,
      "gen_ai.provider.name" => provider,
      "gen_ai.request.model" => model
    }

    attributes =
      if Map.get(metadata, :call_kind) == :stream,
        do: Map.put(attributes, "gen_ai.request.stream", true),
        else: attributes

    {"chat " <> model, :client, attributes,
     suffix == :exception or Map.get(metadata, :outcome, :ok) != :ok}
  end

  defp describe([:lemon_agent, :tool_call, suffix], metadata) do
    name = label(Map.get(metadata, :tool_name), "unknown")

    {"execute_tool " <> name, :internal,
     %{
       "gen_ai.operation.name" => "execute_tool",
       "gen_ai.tool.name" => name,
       "lemon.tool.timeout" => Map.get(metadata, :timeout) == true
     }, suffix == :exception or Map.get(metadata, :is_error) == true}
  end

  # Lemon input is the noncached subset; GenAI input includes both cache
  # categories. An unreported category is unknown, not a measured zero.
  defp total_input(attributes, %{
         input_tokens: input,
         cache_read_tokens: read,
         cache_write_tokens: write
       })
       when is_integer(input) and input >= 0 and is_integer(read) and read >= 0 and
              is_integer(write) and write >= 0 do
    Map.put(attributes, "gen_ai.usage.input_tokens", input + read + write)
  end

  defp total_input(attributes, _measurements), do: attributes

  defp label(value, _default) when is_binary(value), do: value
  defp label(value, _default) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label(_value, default), do: default

  defp error_type([:lemon_ai, :model_call, _]), do: "model_call_error"
  defp error_type([:lemon_agent, :tool_call, _]), do: "tool_call_error"

  defp export({exporter, config}, span) do
    case exporter.export_span(span, config) do
      :ok -> :ok
      _ -> export_failed()
    end
  rescue
    _ -> export_failed()
  catch
    _, _ -> export_failed()
  end

  defp export_failed do
    Logger.warning("GenAI span export failed")
    :ok
  end
end
