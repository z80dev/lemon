defmodule LemonControlPlane.A2A.Runner do
  @moduledoc false

  require Logger

  alias LemonAgent.Security.ExternalContent
  alias LemonControlPlane.A2A.Config
  alias LemonCore.{A2AStore, Bus, Id, RouterBridge, RunRequest, RunStore, SessionKey}
  alias LemonCore.A2A.Protocol

  @submission_reconciling "Run submission outcome is being reconciled"
  @runner_lease_ms 60_000

  @spec start(binary(), binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def start(peer_id, context_id, text, message_id) do
    case :global.trans({{__MODULE__, {:inbound_message, message_id}}, self()}, fn ->
           start_once(peer_id, context_id, text, message_id)
         end) do
      :aborted -> {:error, :replay_lock_unavailable}
      {:aborted, _reason} -> {:error, :replay_lock_unavailable}
      result -> result
    end
  end

  defp start_once(peer_id, context_id, text, message_id) do
    case A2AStore.get_message(message_id) do
      %{direction: :inbound, peer_id: ^peer_id, task_id: task_id} = message
      when is_binary(task_id) ->
        case A2AStore.get_task(task_id) do
          %{} = task -> resume_existing(task, message)
          _ -> {:error, :replay_task_unavailable}
        end

      %{} ->
        {:error, :message_id_conflict}

      nil ->
        create_and_start(peer_id, context_id, text, message_id)
    end
  end

  defp create_and_start(peer_id, context_id, text, message_id) do
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

      message = %{
        id: message_id,
        direction: :inbound,
        peer_id: peer_id,
        context_id: context_id,
        task_id: task_id,
        role: "ROLE_USER",
        text: text
      }

      with :ok <- A2AStore.put_task(task),
           {:ok, %{task_id: ^task_id}} <- A2AStore.append_message(message),
           {:ok, _task} <- launch_submitted(task, context, peer, config, text) do
        {:ok, A2AStore.get_task(task_id)}
      else
        {:ok, _other_message} -> {:error, :message_id_conflict}
        {:error, _reason} -> {:error, :a2a_store_unavailable}
        _other -> {:error, :a2a_store_unavailable}
      end
    end
  end

  defp resume_existing(%{state: "TASK_STATE_SUBMITTED"} = task, message) do
    config = Config.current()
    peer = Map.get(config.peers, task.peer_id, %{agent_id: config.agent_id, allow_tools: []})

    case A2AStore.get_context(:inbound, task.peer_id, task.context_id) do
      %{} = context -> launch_submitted(task, context, peer, config, message.text)
      _ -> {:error, :replay_context_unavailable}
    end
  end

  defp resume_existing(task, _message), do: {:ok, reconcile(task)}

  defp launch_submitted(task, context, peer, config, text) do
    case claim_runner_lease(task.id) do
      {:ok, :claimed, claimed_task, lease_id} ->
        case Task.Supervisor.start_child(LemonControlPlane.A2A.TaskSupervisor, fn ->
               execute(claimed_task, context, peer, config, text, lease_id)
             end) do
          {:ok, _pid} ->
            {:ok, A2AStore.get_task(task.id) || claimed_task}

          {:error, reason} ->
            _ = release_runner_lease(task.id, lease_id)
            {:error, reason}
        end

      {:ok, :leased, current_task} ->
        {:ok, current_task}

      {:ok, :not_submitted, current_task} ->
        {:ok, reconcile(current_task)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_runner_lease(task_id) do
    lease_id = Id.uuid7()
    now_ms = System.system_time(:millisecond)

    case A2AStore.update_task(task_id, fn current ->
           lease_expires_at_ms = current[:runner_lease_expires_at_ms] || 0

           if current.state == "TASK_STATE_SUBMITTED" and lease_expires_at_ms <= now_ms do
             current
             |> Map.put(:runner_lease_id, lease_id)
             |> Map.put(:runner_lease_expires_at_ms, now_ms + @runner_lease_ms)
           else
             current
           end
         end) do
      {:ok, %{runner_lease_id: ^lease_id} = task} ->
        {:ok, :claimed, task, lease_id}

      {:ok, %{state: "TASK_STATE_SUBMITTED"} = task} ->
        {:ok, :leased, task}

      {:ok, task} ->
        {:ok, :not_submitted, task}

      {:error, _reason} = error ->
        error
    end
  end

  defp release_runner_lease(task_id, lease_id) do
    A2AStore.update_task(task_id, fn current ->
      if current.state == "TASK_STATE_SUBMITTED" and current[:runner_lease_id] == lease_id do
        current
        |> Map.put(:runner_lease_id, nil)
        |> Map.put(:runner_lease_expires_at_ms, nil)
      else
        current
      end
    end)
  end

  @spec wait(binary(), non_neg_integer()) :: {:ok, map()} | {:error, :timeout | :not_found}
  def wait(task_id, timeout_ms) do
    topic = "a2a:task:#{task_id}"
    :ok = Bus.subscribe(topic)

    try do
      task =
        case A2AStore.get_task(task_id) do
          nil -> nil
          task -> reconcile(task)
        end

      case task do
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

  @doc false
  @spec mark_canceled(binary()) :: {:ok, map()} | {:error, term()}
  def mark_canceled(task_id) when is_binary(task_id) do
    case transition_nonterminal(task_id, %{state: "TASK_STATE_CANCELED"}) do
      {:ok, :changed, %{state: "TASK_STATE_CANCELED"} = task} ->
        notify(task.id)
        {:ok, task}

      {:ok, :unchanged, task} ->
        {:ok, task}

      result ->
        result
    end
  end

  @doc false
  @spec reconcile(map()) :: map()
  def reconcile(%{state: "TASK_STATE_SUBMITTED"} = task) do
    case submitted_message(task) do
      %{} = message ->
        case resume_existing(task, message) do
          {:ok, current_task} -> current_task
          {:error, _reason} -> task
        end

      nil ->
        task
    end
  rescue
    _ -> task
  catch
    _, _ -> task
  end

  def reconcile(%{run_id: run_id} = task) when is_binary(run_id) do
    if terminal_task?(task) do
      task
    else
      case completed_from_store(run_id) do
        :running ->
          task

        completion ->
          finalize(task, completion)
          A2AStore.get_task(task.id) || task
      end
    end
  end

  def reconcile(task), do: task

  defp submitted_message(task) do
    task.peer_id
    |> A2AStore.history(task.context_id, limit: 100)
    |> Enum.find(fn message ->
      message.task_id == task.id and message.direction == :inbound and message.role == "ROLE_USER"
    end)
  end

  defp execute(task, context, peer, config, text, lease_id) do
    case runner_lease_owned?(task.id, lease_id) do
      true -> execute_claimed(task, context, peer, config, text, lease_id)
      false -> :ok
    end
  end

  defp runner_lease_owned?(task_id, lease_id) do
    case A2AStore.get_task(task_id) do
      %{state: "TASK_STATE_SUBMITTED", runner_lease_id: ^lease_id} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp transition_submitted_to_working(task_id, lease_id) do
    transition_id = Id.uuid7()

    case A2AStore.update_task(task_id, fn current ->
           if current.state == "TASK_STATE_SUBMITTED" and current[:runner_lease_id] == lease_id do
             current
             |> Map.put(:state, "TASK_STATE_WORKING")
             |> Map.put(:runner_lease_id, nil)
             |> Map.put(:runner_lease_expires_at_ms, nil)
             |> Map.put(:transition_id, transition_id)
           else
             current
           end
         end) do
      {:ok, %{transition_id: ^transition_id} = task} -> {:ok, :changed, task}
      {:ok, task} -> {:ok, :unchanged, task}
      {:error, _reason} = error -> error
    end
  end

  defp execute_claimed(task, context, peer, config, text, lease_id) do
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

    case safe_submit(request) do
      {:ok, _run_id} -> continue_accepted_run(task, config.reply_timeout_ms, lease_id)
      {:error, :outcome_unknown} -> continue_accepted_run(task, config.reply_timeout_ms, lease_id)
      error -> finalize(task, error)
    end
  rescue
    error ->
      Logger.warning("A2A runner failed class=#{failure_class(error)}")
      finalize(task, {:error, :runner_failed})
  end

  defp safe_submit(request) do
    RouterBridge.submit_run(request)
  rescue
    _error -> {:error, :outcome_unknown}
  catch
    _kind, _reason -> {:error, :outcome_unknown}
  end

  defp continue_accepted_run(task, timeout_ms, lease_id) do
    case transition_submitted_to_working(task.id, lease_id) do
      {:ok, :changed, %{state: "TASK_STATE_WORKING"}} ->
        result =
          case wait_run(task.run_id, timeout_ms) do
            {:error, :timeout} -> {:error, :outcome_unknown}
            completion -> completion
          end

        finalize(task, result)

      # Cancellation or a newer recovery owner can win while submission is in
      # flight. This runner must not revive or overwrite that durable state.
      {:ok, :unchanged, _current_task} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "A2A accepted-run ownership persistence failed class=#{failure_class(reason)}"
        )

        finalize(task, {:error, :outcome_unknown})
    end
  end

  defp finalize(task, {:ok, answer}) when is_binary(answer) do
    state =
      if String.starts_with?(answer, "[INPUT_REQUIRED]"),
        do: "TASK_STATE_INPUT_REQUIRED",
        else: "TASK_STATE_COMPLETED"

    case transition_nonterminal(task.id, %{state: state, answer: answer, error: nil}) do
      {:ok, :changed, %{state: ^state, answer: ^answer}} ->
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

      {:ok, :unchanged, _terminal_task} ->
        :ok

      {:error, reason} ->
        Logger.warning("A2A task finalization failed class=#{failure_class(reason)}")
    end
  end

  defp finalize(task, {:error, :canceled}) do
    _ = mark_canceled(task.id)
    :ok
  end

  defp finalize(task, {:error, :outcome_unknown}) do
    case transition_nonterminal(task.id, %{
           state: "TASK_STATE_WORKING",
           answer: nil,
           error: @submission_reconciling
         }) do
      {:ok, _, _task} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "A2A task reconciliation persistence failed class=#{failure_class(reason)}"
        )
    end
  end

  defp finalize(task, {:error, reason}) do
    error = if reason == :timeout, do: "peer run timed out", else: "peer run failed"

    case transition_nonterminal(task.id, %{
           state: "TASK_STATE_FAILED",
           answer: nil,
           error: error
         }) do
      {:ok, :changed, %{state: "TASK_STATE_FAILED"}} ->
        notify(task.id)

      {:ok, :unchanged, _terminal_task} ->
        :ok

      {:error, update_reason} ->
        Logger.warning("A2A task finalization failed class=#{failure_class(update_reason)}")
    end
  end

  defp transition_nonterminal(task_id, attrs) when is_map(attrs) do
    transition_id = Id.uuid7()

    case A2AStore.update_task(task_id, fn current ->
           if terminal_task?(current) do
             current
           else
             current
             |> Map.merge(attrs)
             |> Map.put(:transition_id, transition_id)
           end
         end) do
      {:ok, %{transition_id: ^transition_id} = task} -> {:ok, :changed, task}
      {:ok, task} -> {:ok, :unchanged, task}
      {:error, _reason} = error -> error
    end
  end

  defp terminal_task?(%{state: state}) do
    Protocol.terminal_state?(state) or
      state in ["TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"]
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

  defp failure_class(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp failure_class(reason) when is_atom(reason), do: "atom"
  defp failure_class(reason) when is_tuple(reason), do: "tuple"
  defp failure_class(reason) when is_map(reason), do: "map"
  defp failure_class(reason) when is_list(reason), do: "list"
  defp failure_class(_reason), do: "other"
end
