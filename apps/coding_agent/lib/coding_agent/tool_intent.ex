defmodule CodingAgent.ToolIntent do
  @moduledoc """
  Fail-closed dispatch gate for coding-session tools.

  `:none` tools do not write or sync. Every other effect class records a
  content-free `lemon.tool_intent` through the session's live append owner and
  waits for its datasync acknowledgement before calling execute. Results remain
  ordinary ordered, unsynced journal appends. Argument digests are SHA-256 over
  deterministic Erlang encoding of the decoded arguments; raw arguments are not
  copied into the intent.

  `[:coding_agent, :tool_intent, :stop]` reports `duration_us` for digesting,
  owner queueing, append and sync (not tool execution), with effect and status.
  Use this hook to measure added per-call latency on the target filesystem.
  `:tool_intent_recorder` and `:tool_intent_file_module` are scoped test seams,
  not application-global settings.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @receipt_key {__MODULE__, :controller_intent}
  @read_only_builtins ~w(read read_skill recall lsp_diagnostics bash_output grep find semantic_find ls webfetch websearch extensions_status)

  @scope_key {__MODULE__, :parent_scope}
  @doc false
  def builtin_effect(name) when name in @read_only_builtins, do: :none
  def builtin_effect(_name), do: :external

  @doc false
  def wrap(%AgentTool{effect: :none} = tool, _opts), do: tool

  def wrap(%AgentTool{} = tool, opts) do
    execute = tool.execute
    effect = if tool.effect == :idempotent, do: :idempotent, else: :external

    %{
      tool
      | effect: effect,
        on_stream: nil,
        execute: fn id, params, signal, on_update ->
          case record(id, tool.name, params, signal, effect, opts) do
            :ok -> with_receipt(id, fn -> execute.(id, params, signal, on_update) end)
            _failure -> not_run()
          end
        end
    }
  end

  @doc false
  def controller_receipt(id) do
    if Process.get(@receipt_key) == id,
      do: %{"recordedBy" => "controller", "toolCallId" => id},
      else: nil
  end

  @doc false
  def with_parent_scope(id, execute) do
    live = :atomics.new(1, signed: false)
    :atomics.put(live, 1, 1)
    previous = Process.put(@scope_key, {id, self(), live})

    try do
      execute.({id, self(), live})
    after
      :atomics.put(live, 1, 0)

      if previous == nil,
        do: Process.delete(@scope_key),
        else: Process.put(@scope_key, previous)
    end
  end

  @doc false
  def current_parent_scope, do: Process.get(@scope_key)

  @doc false
  def inherit_parent_scope(%AgentTool{} = tool, {id, owner, live}) do
    execute = tool.execute

    %{
      tool
      | execute: fn call_id, params, signal, on_update ->
          if Process.alive?(owner) and :atomics.get(live, 1) == 1 do
            with_receipt(id, fn -> execute.(call_id, params, signal, on_update) end)
          else
            not_run()
          end
        end
    }
  end

  defp record(id, name, params, signal, effect, opts) do
    # This marker is only installed by the authenticated destination service,
    # never taken from model arguments. It is bound to this exact invocation.
    case Keyword.get(opts, :controller_tool_intent) do
      %{"recordedBy" => "controller", "toolCallId" => ^id} -> :ok
      _ -> record_under_parent_or_locally(id, name, params, signal, effect, opts)
    end
  end

  defp record_under_parent_or_locally(id, name, params, signal, effect, opts) do
    case Keyword.get(opts, :controller_parent_intent) do
      %{"recordedBy" => "controller", "toolCallId" => parent_id} ->
        if controller_receipt(parent_id),
          do: :ok,
          else: {:error, :parent_intent_not_live}

      _ ->
        record_locally(id, name, params, signal, effect, opts)
    end
  end

  defp record_locally(id, name, params, signal, effect, opts) do
    started = System.monotonic_time(:microsecond)

    data = %{
      "toolCallId" => id,
      "tool" => name,
      "argumentDigest" =>
        :crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))
        |> Base.encode16(case: :lower),
      "effect" => Atom.to_string(effect)
    }

    result = persist(data, signal, opts)

    LemonCore.Telemetry.emit(
      [:coding_agent, :tool_intent, :stop],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{effect: effect, status: if(result == :ok, do: :ok, else: :error)}
    )

    result
  end

  defp persist(data, signal, opts) do
    case Keyword.get(opts, :tool_intent_recorder) do
      recorder when is_function(recorder, 1) -> recorder.(data)
      _ -> persist_to_owner(Keyword.get(opts, :session_pid), data, signal)
    end
  rescue
    _error -> {:error, :intent_unavailable}
  catch
    _kind, _reason -> {:error, :intent_unavailable}
  end

  defp persist_to_owner(owner, data, signal) when is_pid(owner) and owner != self() do
    GenServer.call(
      owner,
      {:record_tool_intent, data, signal, Process.get(@receipt_key)},
      :infinity
    )
  end

  defp persist_to_owner(_owner, _data, _signal), do: {:error, :intent_owner_unavailable}

  defp with_receipt(id, execute) do
    previous = Process.put(@receipt_key, id)

    try do
      execute.()
    after
      if previous == nil,
        do: Process.delete(@receipt_key),
        else: Process.put(@receipt_key, previous)
    end
  end

  defp not_run do
    %AgentToolResult{
      content: [
        %TextContent{
          text: "Tool not run: its intent could not be durably recorded. Outcome: not started."
        }
      ],
      details: %{outcome: :not_started, started: false, reason: :intent_not_durable},
      is_error: true
    }
  end
end
