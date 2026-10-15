defmodule CodingAgent.Tools.Eval do
  @moduledoc """
  `eval` tool: run code cells in persistent per-session Python or JavaScript
  kernels.

  Each `{session, language}` pair owns one kernel (`CodingAgent.Eval.Kernel`
  under `CodingAgent.Eval.KernelSupervisor`) running in the session cwd, so
  variables, imports and definitions persist across calls. Python runs under
  `python3` (fallback `python`); JavaScript under `bun` (fallback `node`).
  Output streams through `on_update`; the final result holds combined
  stdout/stderr followed by the trailing expression's value or the error.

  The cell deadline is `timeout` seconds (default 30, max 600, `0` for no
  deadline). Timeout first interrupts, retaining state when the cell unwinds
  within two seconds; otherwise the process tree is killed. Abort kills directly.
  `display` returns rich content over a bounded private side channel, separate
  from stdout. Text output follows the `bash` cap and spills to an artifact.

  Options: `:session_id` is the durable kernel identity and `:session_pid`
  binds its current owner. Successful native turn handoff detaches that owner
  before stop; unexpected owner death still disposes of the kernel.
  `:eval_idle_timeout_ms` (default 30 minutes) kills idle kernels, and
  `:eval_runtimes` (`%{"py" => exe, "js" => exe}`) overrides the runtime
  executables.
  """

  alias CodingAgent.Eval.{Kernel, KernelSupervisor, Output}
  alias CodingAgent.Tools.Bash.StreamingPreview
  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @default_timeout_s 30
  @max_timeout_s 600
  @runtimes %{"py" => ["python3", "python"], "js" => ["bun", "node"]}
  @language_names %{"py" => "Python", "js" => "JavaScript"}

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "eval",
      timeout_ms: :infinity,
      description:
        "Run one step of code in a persistent kernel: `py` (Python 3) or `js` (Bun, or Node). " <>
          "Variables, imports and functions persist across calls in this session, so work " <>
          "incrementally (imports, then definitions, then use) and never re-import or re-declare " <>
          "without need. The last expression's value is displayed; print output is captured. " <>
          "Top-level `await` works in both languages. Code runs in the project root; JS has " <>
          "`require` and `import` resolved from there. Use display(value) for PNG/JPEG bytes, " <>
          "markdown or JSON. Python supports standalone %pip install and %load magics. " <>
          "Timeout first interrupts with a two-second grace to preserve state; abort or an " <>
          "unresponsive interrupt kills the kernel. `reset: true` starts that language fresh.",
      label: "Eval",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "language" => %{
            "type" => "string",
            "enum" => ["py", "js"],
            "description" => "Kernel language: \"py\" (Python) or \"js\" (JavaScript)"
          },
          "code" => %{"type" => "string", "description" => "Code to run in the kernel"},
          "title" => %{
            "type" => "string",
            "description" => "Short label for this step (e.g. \"imports\", \"load config\")"
          },
          "timeout" => %{
            "type" => "number",
            "minimum" => 0,
            "maximum" => @max_timeout_s,
            "description" =>
              "Cell deadline in seconds (default #{@default_timeout_s}, max #{@max_timeout_s}); " <>
                "0 disables the deadline. Expiry kills the kernel and loses its state."
          },
          "reset" => %{
            "type" => "boolean",
            "description" =>
              "Discard this language's kernel state before running (default false). " <>
                "The other language's kernel is untouched."
          }
        },
        "required" => ["language", "code"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, on_update, cwd, opts) do
    started = System.monotonic_time(:millisecond)

    with {:ok, request} <- validate(params) do
      if AbortSignal.aborted?(signal) do
        finish(request, :not_started, Output.new(), nil, started)
      else
        request
        |> run(signal, on_update, cwd, opts, started)
        |> CodingAgent.Artifacts.attach(cwd, opts)
        |> ToolResultTrust.untrusted(:shell)
      end
    end
  end

  defp validate(params) do
    language = Map.get(params, "language")
    code = Map.get(params, "code")
    title = Map.get(params, "title")
    reset = Map.get(params, "reset", false)

    cond do
      language not in ["py", "js"] ->
        {:error, "language must be \"py\" or \"js\""}

      not is_binary(code) or String.trim(code) == "" ->
        {:error, "code must be a non-empty string"}

      not (is_nil(title) or is_binary(title)) ->
        {:error, "title must be a string"}

      not is_boolean(reset) ->
        {:error, "reset must be a boolean"}

      true ->
        with {:ok, timeout_ms} <- timeout_ms(Map.get(params, "timeout")) do
          {:ok,
           %{language: language, code: code, title: title, reset: reset, timeout_ms: timeout_ms}}
        end
    end
  end

  defp timeout_ms(nil), do: {:ok, @default_timeout_s * 1000}
  defp timeout_ms(seconds) when seconds == 0, do: {:ok, :infinity}

  defp timeout_ms(seconds) when is_number(seconds) and seconds > 0,
    do: {:ok, max(round(min(seconds, @max_timeout_s) * 1000), 1)}

  defp timeout_ms(_),
    do: {:error, "timeout must be a number of seconds between 0 and #{@max_timeout_s}"}

  defp run(request, signal, on_update, cwd, opts, started) do
    owner = Keyword.get(opts, :session_id) || {:cwd, Path.expand(cwd)}

    with {:ok, runtime} <- resolve_runtime(request.language, opts),
         {:ok, slot} <-
           KernelSupervisor.ensure_slot({owner, request.language},
             language: request.language,
             cwd: Path.expand(cwd),
             runtime: runtime,
             owner_pid: Keyword.get(opts, :session_pid),
             session_key: Keyword.get(opts, :session_key),
             pip_command: Keyword.get(opts, :eval_pip_command),
             idle_timeout_ms: Keyword.get(opts, :eval_idle_timeout_ms)
           ),
         {:ok, %{ref: ref, restarted: restarted}} <-
           start_cell(slot, request) do
      monitor = Process.monitor(slot)

      deadline =
        if request.timeout_ms != :infinity,
          do: Process.send_after(self(), {:lemon_eval_deadline, ref}, request.timeout_ms)

      ctx = %{
        slot: slot,
        ref: ref,
        monitor: monitor,
        signal: signal,
        on_update: on_update
      }

      preview = if is_function(on_update, 1), do: StreamingPreview.new()
      {status, acc} = collect(ctx, Output.new(), preview)

      if deadline, do: Process.cancel_timer(deadline)
      Process.demonitor(monitor, [:flush])

      receive do
        {:lemon_eval_deadline, ^ref} -> :ok
      after
        0 -> :ok
      end

      finish(request, status, acc, restarted, started)
    end
  end

  defp start_cell(slot, request) do
    case Kernel.run(slot, request.code, reset: request.reset) do
      {:ok, _} = ok ->
        ok

      {:error, :busy} ->
        {:error, "the #{request.language} kernel is already running another cell in this session"}

      {:error, reason} when is_binary(reason) ->
        {:error, "#{@language_names[request.language]} kernel failed to start: #{reason}"}

      {:error, reason} ->
        {:error,
         "#{@language_names[request.language]} kernel failed to start: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "eval kernel unavailable: #{inspect(reason)}"}
  end

  defp resolve_runtime(language, opts) do
    candidates =
      case opts |> Keyword.get(:eval_runtimes, %{}) |> Map.get(language) do
        nil -> Map.fetch!(@runtimes, language)
        executable -> [executable]
      end

    case Enum.find_value(candidates, &System.find_executable/1) do
      nil ->
        {:error,
         "eval language \"#{language}\" needs #{Enum.join(candidates, " or ")} on PATH; " <>
           "none was found"}

      path ->
        {:ok, path}
    end
  end

  # ── Cell collection ──────────────────────────────────────────────────────

  defp collect(%{ref: ref, monitor: monitor} = ctx, acc, preview) do
    receive do
      {:lemon_eval, ^ref, {:output, data}} ->
        {acc, text} = Output.append(acc, data)
        preview = stream(ctx, preview, text)

        if AbortSignal.aborted?(ctx.signal),
          do: interrupt(ctx, :aborted, acc),
          else: collect(ctx, acc, preview)

      {:lemon_eval, ^ref, {:result, frame}} ->
        {{:result, frame}, acc}

      {:lemon_eval, ^ref, {:exited, status}} ->
        {{:exited, status}, acc}

      {:lemon_eval_deadline, ^ref} ->
        interrupt(ctx, :timeout, acc)

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {{:slot_down, reason}, drain(ref, acc)}
    after
      100 ->
        if AbortSignal.aborted?(ctx.signal),
          do: interrupt(ctx, :aborted, acc),
          else: collect(ctx, acc, preview)
    end
  end

  # The slot relays output and the interrupted result ahead of its reply.
  defp interrupt(ctx, reason, acc) do
    outcome = Kernel.interrupt(ctx.slot, ctx.ref, reason)
    status = if reason == :timeout, do: {:timeout, outcome}, else: reason
    {status, drain(ctx.ref, acc)}
  end

  defp drain(ref, acc) do
    receive do
      {:lemon_eval, ^ref, {:output, data}} ->
        {acc, _text} = Output.append(acc, data)
        drain(ref, acc)

      {:lemon_eval, ^ref, {:result, frame}} ->
        drain(ref, %{acc | rich: frame["outputs"] || []})

      {:lemon_eval, ^ref, _other} ->
        drain(ref, acc)
    after
      0 -> acc
    end
  end

  defp stream(_ctx, nil, _text), do: nil
  defp stream(_ctx, preview, ""), do: preview

  defp stream(ctx, preview, text) do
    preview = StreamingPreview.append(preview, text)

    ctx.on_update.(
      ToolResultTrust.untrusted(
        %AgentToolResult{content: [%TextContent{text: StreamingPreview.render(preview)}]},
        :shell
      )
    )

    preview
  end

  # ── Result ───────────────────────────────────────────────────────────────

  defp finish(request, outcome, acc, restarted, started) do
    acc =
      case outcome do
        {:result, frame} -> %{acc | rich: frame["outputs"] || []}
        _ -> acc
      end

    {status, acc, notice} = outcome_text(request, outcome, acc)
    final = Output.finalize(acc)

    output =
      if final.truncated and final.full_output_path do
        final.output <>
          "\n\n[Full output saved to: #{final.full_output_path}. " <>
          "Use read with offset/limit to retrieve it.]"
      else
        final.output
      end

    sections =
      [restart_note(request, restarted), output, notice]
      |> Enum.reject(&(&1 in [nil, ""]))

    text = if sections == [], do: "(no output)", else: Enum.join(sections, "\n\n")

    %AgentToolResult{
      content: [%TextContent{text: text} | acc.rich],
      details: %{
        language: request.language,
        title: request.title,
        status: status,
        duration_ms: System.monotonic_time(:millisecond) - started,
        kernel_restarted: restarted != nil,
        truncated: final.truncated,
        full_output_path: final.full_output_path
      },
      is_error: status != :ok
    }
  end

  defp outcome_text(_request, {:result, %{"status" => "ok"} = frame}, acc) do
    case frame["display"] do
      display when is_binary(display) and display != "" ->
        {:ok, Output.append_block(acc, display), nil}

      _ ->
        {:ok, acc, nil}
    end
  end

  defp outcome_text(_request, {:result, frame}, acc) do
    error = frame["error"]
    error = if is_binary(error) and error != "", do: String.trim_trailing(error), else: "Error"
    {:error, Output.append_block(acc, error), nil}
  end

  defp outcome_text(request, {:exited, status}, acc) do
    {:error, acc,
     "The #{language_name(request)} kernel exited (status #{status}); its state was lost. " <>
       "The next call starts a fresh kernel."}
  end

  defp outcome_text(request, {:slot_down, _reason}, acc) do
    {:error, acc,
     "The #{language_name(request)} kernel stopped unexpectedly; its state was lost. " <>
       "The next call starts a fresh kernel."}
  end

  defp outcome_text(request, {:timeout, :preserved}, acc) do
    {:timeout, acc,
     "Eval timed out after #{format_seconds(request.timeout_ms)}; the cell was interrupted. " <>
       "The #{language_name(request)} kernel state was preserved."}
  end

  defp outcome_text(request, {:timeout, :killed}, acc),
    do: outcome_text(request, :timeout, acc)

  defp outcome_text(request, :timeout, acc) do
    {:timeout, acc,
     "Eval timed out after #{format_seconds(request.timeout_ms)}: the #{language_name(request)} " <>
       "kernel was killed and its state (variables, imports, definitions) was lost. The next " <>
       "call starts a fresh kernel. Pass a larger timeout (max #{@max_timeout_s}s, 0 = no " <>
       "deadline) or split the work into smaller steps."}
  end

  defp outcome_text(_request, :not_started, acc) do
    {:aborted, acc, "Eval cancelled before it started."}
  end

  defp outcome_text(request, :aborted, acc) do
    {:aborted, acc,
     "Eval cancelled: the #{language_name(request)} kernel was killed and its state was lost."}
  end

  defp restart_note(_request, nil), do: nil
  defp restart_note(%{reset: true} = request, _), do: "[#{language_name(request)} kernel reset]"

  defp restart_note(request, reason) do
    "[Started a fresh #{language_name(request)} kernel: the previous one ended " <>
      "(#{restart_reason(reason)}), so earlier variables, imports and definitions are gone.]"
  end

  defp restart_reason(:timeout), do: "timed out"
  defp restart_reason(:aborted), do: "cancelled"
  defp restart_reason(:crashed), do: "exited"
  defp restart_reason(:idle), do: "idle timeout"
  defp restart_reason(:reset), do: "reset"

  defp language_name(request), do: Map.fetch!(@language_names, request.language)

  defp format_seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_seconds(ms), do: "#{Float.round(ms / 1000, 3)}s"
end
