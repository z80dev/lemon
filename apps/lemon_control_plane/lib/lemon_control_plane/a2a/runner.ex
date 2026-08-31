defmodule LemonControlPlane.A2A.Runner do
  @moduledoc false

  require Logger

  alias LemonAgent.Security.ExternalContent
  alias LemonControlPlane.A2A.Config
  alias LemonCore.{A2AStore, Bus, Id, RouterBridge, RunRequest, RunStore, SessionKey}

  @spec start(binary(), binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def start(peer_id, context_id, text, message_id) do
    config = Config.current()
    peer = Map.get(config.peers, peer_id, %{agent_id: config.agent_id, allow_tools: []})
    agent_id = peer.agent_id || config.agent_id

    with {:ok, context} <- ensure_context(peer_id, context_id, agent_id),
         :ok <- enforce_turn_limit(context, config.max_context_turns) do
      task_id = Id.uuid7()
      run_id = Id.run_id()

      task = %{
        id: task_id,
        direction: :inbound,
        peer_id: peer_id,
        context_id: context_id,
        run_id: run_id,
        state: "TASK_STATE_SUBMITTED"
      }

      :ok = A2AStore.put_task(task)

      {:ok, _} =
        A2AStore.append_message(%{
          id: message_id,
          direction: :inbound,
          peer_id: peer_id,
          context_id: context_id,
          task_id: task_id,
          role: "ROLE_USER",
          text: text
        })

      case Task.Supervisor.start_child(LemonControlPlane.A2A.TaskSupervisor, fn ->
             execute(task, context, peer, config, text)
           end) do
        {:ok, _pid} ->
          {:ok, A2AStore.get_task(task_id)}

        {:error, reason} ->
          _ =
            A2AStore.update_task(
              task_id,
              &Map.merge(&1, %{state: "TASK_STATE_FAILED", error: "runner unavailable"})
            )

          {:error, reason}
      end
    end
  end

  @spec wait(binary(), non_neg_integer()) :: {:ok, map()} | {:error, :timeout | :not_found}
  def wait(task_id, timeout_ms) do
    topic = "a2a:task:#{task_id}"
    :ok = Bus.subscribe(topic)

    try do
      case A2AStore.get_task(task_id) do
        nil ->
          {:error, :not_found}

        %{state: state} = task
        when state in [
               "TASK_STATE_COMPLETED",
               "TASK_STATE_FAILED",
               "TASK_STATE_CANCELED",
               "TASK_STATE_REJECTED",
               "TASK_STATE_INPUT_REQUIRED",
               "TASK_STATE_AUTH_REQUIRED"
             ] ->
          {:ok, task}

        _ ->
          receive do
            {:a2a_task_terminal, ^task_id} -> {:ok, A2AStore.get_task(task_id)}
          after
            timeout_ms -> {:error, :timeout}
          end
      end
    after
      Bus.unsubscribe(topic)
    end
  end

  defp execute(task, context, peer, config, text) do
    {:ok, _} = A2AStore.update_task(task.id, &Map.put(&1, :state, "TASK_STATE_WORKING"))

    allow_tools =
      if peer.allow_tools == [], do: config.default_allow_tools, else: peer.allow_tools

    request =
      RunRequest.new(%{
        origin: :control_plane,
        run_id: task.run_id,
        session_key: context.session_key,
        agent_id: context.agent_id,
        prompt:
          ExternalContent.wrap_external_content(text,
            source: :api,
            sender: "A2A peer #{task.peer_id}",
            max_bytes: 256_000
          ),
        queue_mode: :followup,
        tool_policy: %{allow: allow_tools},
        meta: %{a2a: true, a2a_peer_id: task.peer_id, a2a_context_id: task.context_id}
      })

    result =
      with {:ok, _run_id} <- RouterBridge.submit_run(request) do
        wait_run(task.run_id, config.reply_timeout_ms)
      end

    finalize(task, result)
  rescue
    error ->
      Logger.warning("A2A runner failed: #{Exception.message(error)}")
      finalize(task, {:error, :runner_failed})
  end

  defp finalize(task, {:ok, answer}) when is_binary(answer) do
    state =
      if String.starts_with?(answer, "[INPUT_REQUIRED]"),
        do: "TASK_STATE_INPUT_REQUIRED",
        else: "TASK_STATE_COMPLETED"

    {:ok, _} = A2AStore.update_task(task.id, &Map.merge(&1, %{state: state, answer: answer}))
    {:ok, _} = A2AStore.increment_turn(:inbound, task.peer_id, task.context_id)

    {:ok, _} =
      A2AStore.append_message(%{
        direction: :inbound,
        peer_id: task.peer_id,
        context_id: task.context_id,
        task_id: task.id,
        role: "ROLE_AGENT",
        text: answer
      })

    notify(task.id)
  end

  defp finalize(task, {:error, :canceled}) do
    {:ok, _} = A2AStore.update_task(task.id, &Map.put(&1, :state, "TASK_STATE_CANCELED"))
    notify(task.id)
  end

  defp finalize(task, {:error, reason}) do
    error = if reason == :timeout, do: "peer run timed out", else: "peer run failed"

    {:ok, _} =
      A2AStore.update_task(task.id, &Map.merge(&1, %{state: "TASK_STATE_FAILED", error: error}))

    notify(task.id)
  end

  defp wait_run(run_id, timeout_ms) do
    topic = Bus.run_topic(run_id)
    :ok = Bus.subscribe(topic)

    try do
      case completed_from_store(run_id) do
        {:ok, _} = complete -> complete
        :running -> wait_event(timeout_ms)
      end
    after
      Bus.unsubscribe(topic)
    end
  end

  defp wait_event(timeout_ms) do
    receive do
      %LemonCore.Event{type: :run_completed, payload: payload} -> completion(payload)
      %{type: :run_completed, payload: payload} -> completion(payload)
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp completed_from_store(run_id) do
    case RunStore.get(run_id) do
      %{summary: %{completed: completed}} when not is_nil(completed) -> completion(completed)
      _ -> :running
    end
  rescue
    _ -> :running
  end

  defp completion(payload) do
    completed = Map.get(payload, :completed) || Map.get(payload, "completed") || payload
    ok = Map.get(completed, :ok, Map.get(completed, "ok"))
    answer = Map.get(completed, :answer, Map.get(completed, "answer"))

    cond do
      ok == true -> {:ok, to_string(answer || "")}
      Map.get(completed, :error) == :aborted -> {:error, :canceled}
      true -> {:error, :run_failed}
    end
  end

  defp ensure_context(peer_id, context_id, agent_id) do
    peer_hash = digest(peer_id)
    context_hash = digest(context_id)

    A2AStore.ensure_context(:inbound, peer_id, context_id, %{
      agent_id: agent_id,
      session_key:
        SessionKey.channel_peer(%{
          agent_id: agent_id,
          channel_id: "a2a",
          account_id: "lemon",
          peer_kind: :dm,
          peer_id: peer_hash,
          thread_id: context_hash
        })
    })
  end

  defp enforce_turn_limit(%{turn_count: turns}, max) when turns < max, do: :ok
  defp enforce_turn_limit(_, _), do: {:error, :turn_limit}

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false) |> binary_part(0, 22)

  defp notify(task_id), do: Bus.broadcast("a2a:task:#{task_id}", {:a2a_task_terminal, task_id})
end
