if Code.ensure_loaded?(:otel_tracer) do
  defmodule LemonAgent.GenAISpans.OpenTelemetry do
    @moduledoc """
    Exports completed GenAI spans through the optional Erlang OpenTelemetry API.

    Compiled only when `opentelemetry_api` is available. The embedding application
    must start an OpenTelemetry SDK and configure its processors/exporters; the
    API alone is non-recording. No SDK or network exporter is required by Lemon.

    Timestamps are native monotonic units, as required by `:otel_tracer` and
    `:otel_span`. Spans are roots, with no implicit tracker-process parent and
    no changes to the emitting process's current span. `:exporter_config` is
    unused by this adapter; configure the SDK through its own application env.
    """

    @behaviour LemonAgent.GenAISpans.Exporter

    @impl true
    def export_span(span, _config) do
      tracer = :opentelemetry.get_tracer(:lemon_agent)

      context =
        :otel_tracer.start_span(:otel_ctx.new(), tracer, span.name, %{
          kind: span.kind,
          start_time: span.start_time,
          attributes: span.attributes
        })

      :otel_span.set_status(context, span.status)
      _ = :otel_span.end_span(context, span.end_time)
      :ok
    end
  end
end
