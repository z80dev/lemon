defmodule LemonAgent.GenAISpans.Exporter do
  @moduledoc """
  Receives completed, content-free model and tool spans.

  All times (`start_time`, `end_time`, `duration`) are **native monotonic**
  units, like the source telemetry and the Erlang OpenTelemetry API. Convert
  with `System.convert_time_unit/3` only at an exporter boundary. `attributes`
  is an explicit allowlist, never the original event metadata.

  Callbacks run synchronously in the emitting process. Implementations must
  return quickly (for example, enqueue into an SDK batch processor), must not
  perform network I/O here, and must not add prompts or tool arguments/results.
  Failures are isolated by the attachment and logged without exception content.
  """

  @type span :: %{
          name: String.t(),
          kind: :client | :internal,
          start_time: integer(),
          end_time: integer(),
          duration: non_neg_integer(),
          status: :unset | :error,
          attributes: %{String.t() => String.t() | non_neg_integer() | boolean()}
        }

  @callback export_span(span(), term()) :: :ok | {:error, term()}
end
