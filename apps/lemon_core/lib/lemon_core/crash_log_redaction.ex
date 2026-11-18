defmodule LemonCore.CrashLogRedaction do
  @moduledoc """
  Primary `:logger` filter that strips conversation content from OTP crash
  reports before any handler (console, file, Sentry) sees them.

  `format_status/1` only covers what a process chooses to redact; OTP still
  attaches the original stacktrace (with function-clause arguments), the
  pending message queue and the process dictionary to its reports. This filter
  runs ahead of Elixir's translator and rewrites:

    * `gen_server` / `gen_statem` terminate reports: reason reduced with
      `LemonCore.StatusRedaction.reason/1`, stacktrace arguments reduced to
      arity, last message/queue/postponed/log/client info dropped, state replaced
      (a `gen_statem` keeps its atom state name) and timeouts reduced to atoms;
    * `proc_lib` crash reports: `error_info` reduced the same way, message queue,
      dictionary and neighbour details dropped, initial call arguments reduced;
    * supervisor reports: reason reduced and child start arguments dropped;
    * `Task` terminating reports, unexpected `handle_info` messages and the
      emulator's "Error in process" exit values.

  See `docs/error-reporting.md`. Installed by `LemonCore.Application.start/2`.
  """

  alias LemonCore.StatusRedaction

  @filter_id :lemon_crash_log_redaction

  @doc "Installs the filter as the first primary filter (idempotent)."
  @spec install() :: :ok
  def install do
    %{filters: filters} = :logger.get_primary_config()
    filters = List.keydelete(filters, @filter_id, 0)

    :logger.update_primary_config(%{
      filters: [{@filter_id, {&__MODULE__.filter/2, []}} | filters]
    })
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(event, _extra) do
    redact_event(event)
  rescue
    # A filter that raises is removed by :logger; fail closed instead.
    _ -> %{event | msg: {:string, "[crash report redacted]"}}
  end

  defp redact_event(%{msg: {:report, report}} = event) when is_map(report) or is_list(report) do
    case redact_report(report) do
      ^report -> event
      redacted -> %{event | msg: {:report, redacted}}
    end
  end

  defp redact_event(%{msg: {format, [pid, node, exit_value]}} = event) when is_list(format) do
    if List.starts_with?(format, ~c"Error in process ") do
      %{event | msg: {format, [pid, node, StatusRedaction.reason(exit_value)]}}
    else
      event
    end
  end

  defp redact_event(event), do: event

  defp redact_report(%{label: {:gen_server, :terminate}} = report) do
    report
    |> update(:reason, &StatusRedaction.reason/1)
    |> put_if(:last_message, :redacted)
    |> put_if(:state, :redacted)
    |> put_if(:log, [])
    |> put_if(:client_info, :undefined)
  end

  defp redact_report(%{label: {:gen_statem, :terminate}} = report) do
    report
    |> update(:reason, &StatusRedaction.error_info/1)
    |> update(:state, &statem_state/1)
    |> put_if(:queue, [])
    |> put_if(:postponed, [])
    |> put_if(:log, [])
    |> put_if(:client_info, :undefined)
    |> update(:timeouts, &statem_timeouts/1)
  end

  defp redact_report(%{label: {:proc_lib, :crash}, report: [info | _neighbours]} = report)
       when is_list(info) do
    info =
      info
      |> kw_update(:error_info, &StatusRedaction.error_info/1)
      |> kw_update(:initial_call, &mfa/1)
      |> kw_update(:messages, fn _ -> [] end)
      |> kw_update(:dictionary, fn _ -> [] end)

    %{report | report: [info, []]}
  end

  defp redact_report(%{label: {:supervisor, _}, report: info} = report) when is_list(info) do
    info =
      info
      |> kw_update(:reason, &StatusRedaction.reason/1)
      |> kw_update(:offender, &offender/1)

    %{report | report: info}
  end

  defp redact_report(%{label: {Task.Supervisor, :terminating}, report: info} = report)
       when is_map(info) do
    info =
      info
      |> update(:reason, &StatusRedaction.reason/1)
      |> update(:args, &Enum.map(List.wrap(&1), fn _ -> :redacted end))

    %{report | report: info}
  end

  defp redact_report(%{label: {GenServer, :no_handle_info}, report: info} = report)
       when is_map(info) do
    %{report | report: put_if(info, :message, :redacted)}
  end

  defp redact_report(report), do: report

  defp statem_state({name, _data}) when is_atom(name), do: {name, :redacted}
  defp statem_state(_state), do: {:redacted, :redacted}

  defp statem_timeouts({_count, timeouts}) when is_list(timeouts) do
    kept =
      for {name, content} <- timeouts do
        {atom_or_redacted(name), atom_or_redacted(content)}
      end

    {length(kept), kept}
  end

  defp statem_timeouts(_timeouts), do: {0, []}

  defp atom_or_redacted(value) when is_atom(value), do: value
  defp atom_or_redacted({:timeout, name}) when is_atom(name), do: {:timeout, name}
  defp atom_or_redacted(_value), do: :redacted

  defp offender(offender) when is_list(offender) do
    offender
    |> kw_update(:mfargs, &mfa/1)
    |> kw_update(:mfa, &mfa/1)
  end

  defp offender(_offender), do: []

  defp mfa({m, f, args}) when is_list(args), do: {m, f, Enum.map(args, fn _ -> :redacted end)}
  defp mfa({m, f, arity}) when is_integer(arity), do: {m, f, arity}
  defp mfa(_other), do: :redacted

  defp update(map, key, fun) do
    case map do
      %{^key => value} -> %{map | key => fun.(value)}
      _ -> map
    end
  end

  defp put_if(map, key, value) do
    if Map.has_key?(map, key), do: %{map | key => value}, else: map
  end

  defp kw_update(list, key, fun) do
    Enum.map(list, fn
      {^key, value} -> {key, fun.(value)}
      other -> other
    end)
  end
end
