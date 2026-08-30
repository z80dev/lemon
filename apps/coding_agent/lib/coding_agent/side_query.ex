defmodule CodingAgent.SideQuery do
  @moduledoc """
  Bounded, no-tools side queries for Hermes-compatible `/btw` commands.

  A side query runs in a new ephemeral `CodingAgent.Session`. With a live
  parent it freezes one atomic transcript/system-prompt snapshot. With a
  durable channel `session_key` it rebuilds a bounded transcript from
  `LemonCore.RunStore` and reuses durable session model/thinking policy. The
  isolated session has an explicit empty tool list and never writes to, steers,
  or appends the parent conversation.
  """

  alias CodingAgent.{Session, SessionRegistry}
  alias CodingAgent.Tools.Task.{Result, Runner}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{AssistantMessage, TextContent, UserMessage}
  alias LemonCore.{MapHelpers, PolicyStore, RouterBridge, RunStore}

  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  @default_history_runs 20
  @max_history_runs 50

  @type source :: pid() | String.t() | %{required(:messages) => list()}

  @doc "Run a synchronous no-tools question against an immutable parent-context snapshot."
  @spec ask(source(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(source, question, opts \\ [])

  def ask(source, question, opts) when is_binary(question) and is_list(opts) do
    question = String.trim(question)

    if question == "" do
      {:error, :empty_question}
    else
      with {:ok, context} <- resolve_context(source, opts) do
        run(context, question, opts)
      end
    end
  end

  def ask(_source, _question, _opts), do: {:error, :invalid_question}

  defp resolve_context(pid, _opts) when is_pid(pid), do: live_context(pid)

  defp resolve_context(%{messages: messages, system_prompt: system_prompt} = snapshot, _opts)
       when is_list(messages) and is_binary(system_prompt) do
    {:ok,
     %{
       mode: :snapshot,
       snapshot: %{messages: messages, system_prompt: system_prompt},
       cwd: Map.get(snapshot, :cwd) || LemonCore.Cwd.default_cwd(),
       model: Map.get(snapshot, :model),
       thinking_level: Map.get(snapshot, :thinking_level),
       settings_manager: Map.get(snapshot, :settings_manager),
       workspace_dir: Map.get(snapshot, :workspace_dir),
       source_session_key: Map.get(snapshot, :source_session_key),
       source_agent_id: Map.get(snapshot, :source_agent_id)
     }}
  end

  defp resolve_context(source, opts) when is_binary(source) do
    case SessionRegistry.lookup(source) do
      {:ok, pid} -> live_context(pid)
      :error -> durable_context(source, opts)
    end
  end

  defp resolve_context(_source, _opts), do: {:error, :invalid_source}

  defp live_context(pid) do
    snapshot = Session.context_snapshot(pid)

    {:ok,
     %{
       mode: :snapshot,
       snapshot: %{messages: snapshot.messages, system_prompt: snapshot.system_prompt},
       cwd: snapshot.cwd,
       model: snapshot.model,
       thinking_level: snapshot.thinking_level,
       settings_manager: snapshot.settings_manager,
       workspace_dir: snapshot.workspace_dir,
       source_session_key: snapshot.source_session_key,
       source_agent_id: snapshot.source_agent_id
     }}
  rescue
    _ -> {:error, :session_unavailable}
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp durable_context(session_key, opts) do
    history_fn = Keyword.get(opts, :history_fn, &RunStore.history/2)
    active_run_fn = Keyword.get(opts, :active_run_fn, &RouterBridge.active_run/1)
    run_get_fn = Keyword.get(opts, :run_get_fn, &RunStore.get/1)
    history = history_fn.(session_key, limit: history_limit(opts))
    history = maybe_include_active_summary(history, session_key, active_run_fn, run_get_fn)
    messages = history_messages(history)

    if messages == [] do
      {:error, :session_not_found}
    else
      policy = policy_for(session_key, opts)

      {:ok,
       %{
         mode: :history,
         initial_messages: messages,
         cwd: Keyword.get(opts, :cwd) || LemonCore.Cwd.default_cwd(),
         model: Keyword.get(opts, :model) || MapHelpers.get_key(policy, :model),
         thinking_level:
           Keyword.get(opts, :thinking_level) || MapHelpers.get_key(policy, :thinking_level),
         system_prompt:
           Keyword.get(opts, :system_prompt) || MapHelpers.get_key(policy, :system_prompt),
         source_session_key: session_key,
         source_agent_id: LemonCore.SessionKey.agent_id(session_key)
       }}
    end
  rescue
    _ -> {:error, :history_unavailable}
  catch
    :exit, _ -> {:error, :history_unavailable}
  end

  defp run(context, question, opts) do
    signal = AbortSignal.new()
    timeout_ms = timeout_ms(opts)
    session_id = generate_session_id()
    run_id = "btw_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    session_opts =
      [
        cwd: context.cwd,
        model: context[:model],
        thinking_level: context[:thinking_level],
        system_prompt: context[:system_prompt],
        settings_manager: context[:settings_manager],
        workspace_dir: context[:workspace_dir],
        context_snapshot: context[:snapshot],
        initial_messages: context[:initial_messages],
        tools: [],
        stream_fn: Keyword.get(opts, :stream_fn),
        get_api_key: Keyword.get(opts, :get_api_key),
        session_id: session_id,
        session_key: "side_query:#{run_id}",
        agent_id: context[:source_agent_id] || "default",
        run_id: run_id,
        session_scope: :main,
        register: true
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    runner = Keyword.get(opts, :runner, &default_runner/4)

    try do
      case runner.(session_opts, question, signal, timeout_ms) do
        {:ok, answer} when is_binary(answer) -> {:ok, answer}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_result, other}}
      end
    after
      AbortSignal.abort(signal)
      AbortSignal.clear(signal)
    end
  end

  defp default_runner(session_opts, question, signal, timeout_ms) do
    case Runner.start_session_with_prompt(
           session_opts,
           question,
           "Side query",
           signal,
           nil,
           nil,
           task_session_timeout_ms: timeout_ms
         ) do
      %AgentToolResult{} = result -> {:ok, Result.visible_output_text(result)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  defp history_messages(history) do
    history
    |> Enum.reverse()
    |> Enum.flat_map(fn {_run_id, data} -> history_entry_messages(data) end)
  end

  defp history_entry_messages(data) when is_map(data) do
    summary = MapHelpers.get_key(data, :summary) || %{}
    completed = MapHelpers.get_key(summary, :completed) || %{}
    prompt = normalize_text(MapHelpers.get_key(summary, :prompt))
    answer = normalize_text(MapHelpers.get_key(completed, :answer))
    timestamp = normalize_timestamp(MapHelpers.get_key(data, :started_at))

    []
    |> maybe_append(prompt, fn text ->
      %UserMessage{role: :user, content: text, timestamp: timestamp}
    end)
    |> maybe_append(answer, fn text ->
      %AssistantMessage{
        role: :assistant,
        content: [%TextContent{type: :text, text: text}],
        stop_reason: :stop,
        timestamp: timestamp
      }
    end)
  end

  defp history_entry_messages(_), do: []

  defp maybe_include_active_summary(history, session_key, active_run_fn, run_get_fn) do
    with {:ok, run_id} <- active_run_fn.(session_key),
         false <- Enum.any?(history, fn {history_id, _} -> to_string(history_id) == run_id end),
         record when is_map(record) <- run_get_fn.(run_id),
         summary when is_map(summary) <- MapHelpers.get_key(record, :summary) do
      [
        {run_id, %{summary: summary, started_at: MapHelpers.get_key(record, :started_at)}}
        | history
      ]
    else
      _ -> history
    end
  end

  defp policy_for(session_key, opts) do
    policy_fn = Keyword.get(opts, :policy_fn, &PolicyStore.get_session/1)

    case policy_fn.(session_key) do
      policy when is_map(policy) -> policy
      _ -> %{}
    end
  end

  defp maybe_append(messages, nil, _builder), do: messages
  defp maybe_append(messages, text, builder), do: messages ++ [builder.(text)]

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_), do: nil

  defp normalize_timestamp(value) when is_integer(value), do: value
  defp normalize_timestamp(_), do: System.system_time(:millisecond)

  defp history_limit(opts) do
    case Keyword.get(opts, :history_limit, @default_history_runs) do
      value when is_integer(value) and value > 0 -> min(value, @max_history_runs)
      _ -> @default_history_runs
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, @max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  defp generate_session_id do
    "btw_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end
