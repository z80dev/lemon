defmodule LemonCore.StatusRedaction do
  @moduledoc """
  Shared `format_status/1` redaction for processes that hold prompts, answers
  or other conversation content.

  OTP passes a process's state, last message, exit reason and debug log through
  `format_status/1` before writing crash reports, `:sys.get_status/1` output and
  supervisor reports. Crash reports are forwarded to the error-reporting sink
  (Sentry, see `docs/error-reporting.md`), so prompt-holding processes call these
  helpers to keep only scalar identifiers (`run_id`, `session_key`, phase, …).

  Kept state values must be scalars (atoms, numbers, booleans, pids, refs or
  binaries); any other value under an allowed key becomes `:redacted`. Exit
  reasons keep their shape for triage (exit atoms, the exception module and a
  stacktrace without call arguments) but drop every carried term.
  """

  defmodule RedactedCrashError do
    @moduledoc "Stand-in for an exception whose message may carry conversation content."
    defexception [:message]
  end

  @type keep :: [atom()]

  @doc "Redacts a `GenServer` `format_status/1` map, keeping only `keep` state keys."
  @spec gen_server(map(), keep()) :: map()
  def gen_server(status, keep) when is_map(status) and is_list(keep) do
    Map.new(status, fn
      {:state, state} -> {:state, take(state, keep)}
      {:message, _} -> {:message, :redacted}
      {:reason, reason} -> {:reason, reason(reason)}
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  @doc "Redacts a `:gen_statem` `format_status/1` map, keeping only `keep` data keys."
  @spec gen_statem(map(), keep()) :: map()
  def gen_statem(status, keep) when is_map(status) and is_list(keep) do
    Map.new(status, fn
      {:state, state} when is_atom(state) -> {:state, state}
      {:state, _} -> {:state, :redacted}
      {:data, data} -> {:data, take(data, keep)}
      {:reason, reason} -> {:reason, reason(reason)}
      {:timeouts, timeouts} -> {:timeouts, timeouts(timeouts)}
      {key, _} when key in [:queue, :postponed, :log] -> {key, []}
      {key, _} -> {key, :redacted}
    end)
  end

  @doc "Redacts an exit reason, keeping exit atoms and exception/stacktrace shape only."
  @spec reason(term()) :: term()
  def reason(reason) when is_atom(reason), do: reason
  def reason({:shutdown, inner}) when is_atom(inner), do: {:shutdown, inner}
  def reason({:shutdown, _}), do: {:shutdown, :redacted}

  # OTP 27+ passes `format_status/1` the bare exception and logs the stacktrace separately.
  def reason(%module{} = exception) when is_exception(exception), do: redacted_crash(module)

  def reason({%module{} = exception, stacktrace})
      when is_exception(exception) and is_list(stacktrace) do
    {redacted_crash(module), stacktrace(stacktrace)}
  end

  def reason({reason, stacktrace}) when is_list(stacktrace) do
    cond do
      not stacktrace?(stacktrace) -> tagged(reason)
      is_atom(reason) -> {reason, stacktrace(stacktrace)}
      true -> {tagged(reason), stacktrace(stacktrace)}
    end
  end

  def reason(reason), do: tagged(reason)

  @doc "`inspect/1` of `reason/1`, for log lines about exit or failure reasons."
  @spec inspect_reason(term()) :: String.t()
  def inspect_reason(reason), do: inspect(reason(reason))

  @doc """
  Redacts `{class, reason, stacktrace}` error info (proc_lib crash reports,
  `:gen_statem` terminate reports).
  """
  @spec error_info(term()) :: term()
  def error_info({class, reason, stacktrace}) when is_atom(class) and is_list(stacktrace) do
    {class, reason(reason), stacktrace(stacktrace)}
  end

  def error_info(_error_info), do: :redacted

  @doc "Strips call arguments from stacktrace entries, keeping module/function/arity/location."
  @spec stacktrace(term()) :: list()
  def stacktrace(stacktrace) when is_list(stacktrace), do: strip_stacktrace(stacktrace)
  def stacktrace(_stacktrace), do: []

  # `{:badmatch, term}`-style reasons keep their atom tag only.
  defp tagged(reason) when is_atom(reason), do: reason

  defp tagged(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> {tag, :redacted}
      _ -> :redacted
    end
  end

  defp tagged(_reason), do: :redacted

  defp redacted_crash(module),
    do: %RedactedCrashError{message: "#{inspect(module)} (message redacted)"}

  # Timer names and atom event contents are kept for diagnostics; any other
  # content may carry an event payload.
  defp timeouts(timeouts) when is_list(timeouts) do
    Enum.map(timeouts, fn
      {name, content} -> {atom_or_redacted(name), atom_or_redacted(content)}
      _other -> :redacted
    end)
  end

  defp timeouts(_timeouts), do: []

  defp atom_or_redacted(value) when is_atom(value), do: value
  defp atom_or_redacted({:timeout, name}) when is_atom(name), do: {:timeout, name}
  defp atom_or_redacted(_value), do: :redacted

  defp take(state, keep) when is_map(state) do
    state
    |> Map.take(keep)
    |> Map.new(fn {key, value} -> {key, scalar(value)} end)
  end

  defp take(_state, _keep), do: :redacted

  defp scalar(value)
       when is_atom(value) or is_number(value) or is_pid(value) or is_reference(value) or
              is_binary(value),
       do: value

  defp scalar(_value), do: :redacted

  defp stacktrace?(stacktrace) do
    stacktrace != [] and Enum.all?(stacktrace, &frame?/1)
  end

  defp frame?({_mod, _fun, _arity_or_args, location}) when is_list(location), do: true
  defp frame?({_fun, _arity_or_args, location}) when is_list(location), do: true
  defp frame?(_frame), do: false

  defp strip_stacktrace(stacktrace) do
    Enum.flat_map(stacktrace, fn
      {mod, fun, arity_or_args, location} when is_list(location) ->
        [{mod, fun, arity(arity_or_args), location(location)}]

      {fun, arity_or_args, location} when is_list(location) ->
        [{fun, arity(arity_or_args), location(location)}]

      _other ->
        []
    end)
  end

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity) when is_integer(arity), do: arity
  defp arity(_other), do: 0

  # `error_info` location entries can carry a `cause` term; keep file/line only.
  defp location(location), do: Keyword.take(location, [:file, :line])
end
