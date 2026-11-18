defmodule LemonCore.SentryScrubber do
  @moduledoc """
  Sentry `before_send` callback that keeps conversation content out of error
  reports (see `docs/error-reporting.md`).

  `Sentry.LoggerHandler` copies a crashing process's inspected state, last
  message and exit reason into `extra`, the event message and the exception
  value. Prompt-holding processes already redact those via
  `LemonCore.StatusRedaction`, but any process can crash with user content in
  scope, so every event is reduced to structural data before it leaves the node:

    * `extra` keeps only `pid_which_sent_last_message` and the `file`/`line`
      logger metadata; `genserver_state`, `last_message`, `crash_reason` and
      anything else are dropped.
    * The event message is replaced by a fixed label (`GenServer %s terminating`
      keeps its pid parameter); exception values keep only their type.
    * Stack frame variables, breadcrumbs, request bodies/cookies/query strings and
      fingerprints derived from inspected call terms are removed.

  The module only touches plain map fields so it compiles without the optional
  `:sentry` dependency.
  """

  @genserver_template "GenServer %s terminating"
  @redacted "[redacted]"
  @kept_extra [:pid_which_sent_last_message]
  @kept_metadata [:file, :line]

  @doc "Scrubs a Sentry event; always returns the (scrubbed) event."
  @spec before_send(map()) :: map()
  def before_send(%{} = event) do
    event
    |> update(:extra, &extra/1)
    |> update(:message, &message/1)
    |> update(:exception, &exceptions/1)
    |> update(:threads, &threads/1)
    |> update(:breadcrumbs, fn _ -> [] end)
    |> update(:fingerprint, &fingerprint/1)
    |> update(:request, &request/1)
  end

  defp update(event, key, fun) do
    case event do
      %{^key => value} -> Map.put(event, key, fun.(value))
      _ -> event
    end
  end

  defp extra(extra) when is_map(extra) do
    kept = Map.take(extra, @kept_extra)

    case extra do
      %{logger_metadata: metadata} when is_map(metadata) ->
        Map.put(kept, :logger_metadata, Map.take(metadata, @kept_metadata))

      _ ->
        kept
    end
  end

  defp extra(_extra), do: %{}

  defp message(nil), do: nil

  defp message(%{message: @genserver_template <> _} = message) do
    params = List.wrap(Map.get(message, :params))

    formatted =
      case params do
        [pid | _] when is_binary(pid) -> "GenServer #{pid} terminating"
        _ -> @genserver_template
      end

    %{message | message: @genserver_template, formatted: formatted}
    |> Map.put(:params, Enum.take(params, 1))
  end

  defp message(%{} = message) do
    message
    |> Map.put(:message, @redacted)
    |> Map.put(:formatted, @redacted)
    |> Map.put(:params, [])
  end

  defp message(_message), do: nil

  defp exceptions(values) when is_list(values) do
    Enum.map(values, fn
      %{} = exception ->
        exception
        |> Map.put(:value, @redacted)
        |> update(:stacktrace, &stacktrace/1)
        |> update(:mechanism, &mechanism/1)

      _other ->
        %{type: @redacted, value: @redacted}
    end)
  end

  defp exceptions(_values), do: []

  defp threads(threads) when is_list(threads) do
    Enum.map(threads, fn
      %{} = thread -> update(thread, :stacktrace, &stacktrace/1)
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp threads(_threads), do: nil

  defp mechanism(%{} = mechanism), do: Map.put(mechanism, :data, nil)
  defp mechanism(other), do: other

  defp stacktrace(%{frames: frames} = stacktrace) when is_list(frames) do
    %{stacktrace | frames: Enum.map(frames, &frame/1)}
  end

  defp stacktrace(_stacktrace), do: nil

  defp frame(%{} = frame), do: Map.put(frame, :vars, nil)
  defp frame(_frame), do: nil

  # Sentry.LoggerHandler fingerprints call timeouts with `inspect(call)`, which
  # carries the call payload. Keep the classification, drop the term.
  defp fingerprint([type, "genserver_call" | _]) when is_binary(type),
    do: [type, "genserver_call"]

  defp fingerprint(_fingerprint), do: []

  defp request(%{} = request) do
    Enum.reduce([:data, :cookies, :query_string, :headers, :env], request, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, nil), else: acc
    end)
  end

  defp request(other), do: other
end
