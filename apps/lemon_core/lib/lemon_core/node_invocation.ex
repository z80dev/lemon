defmodule LemonCore.NodeInvocation do
  @moduledoc """
  Temporary owner of one named-node invocation and its pending controls.

  Timers, recipient/socket monitors and sequence validation are local to this
  process. Neither streamed frames nor terminal/control replies visit a shared
  broker. Disconnects are terminal; work is never replayed on another socket.
  """

  use GenServer, restart: :temporary

  alias LemonCore.{JSONPayload, NodeRegistry}

  @max_control_text_bytes 16 * 1_024
  @max_event_bytes 64 * 1_024
  @event_types ~w(delta started action checkpoint_created checkpoint_restored checkpoint_deleted approval_requested)
  # `outcome_unknown` relays a controller decision the store could not confirm;
  # the worker settles its waiter as unknown, never approved or denied.
  @approval_decisions ~w(approve_once approve_session approve_agent approve_global deny outcome_unknown)

  def start_link({node, method, args, opts}) do
    GenServer.start_link(__MODULE__, {node, method, args, opts})
  end

  def call(invoke_id, request, missing) do
    case Registry.lookup(NodeRegistry.Invocations, invoke_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, request)
        catch
          :exit, {:noproc, _} -> missing
          :exit, {:normal, _} -> missing
        end

      [] ->
        missing
    end
  end

  @impl true
  def init({node, method, args, opts}) do
    id = Keyword.fetch!(opts, :invoke_id)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_bytes = Keyword.fetch!(opts, :max_payload_bytes)

    payload = %{
      "invokeId" => id,
      "nodeId" => node.id,
      "nodeGeneration" => node.generation,
      "nodeName" => node.name,
      "method" => method,
      "args" => args,
      "timeoutMs" => timeout_ms
    }

    case JSONPayload.validate(payload, json_opts(method, max_bytes)) do
      {:ok, _} ->
        {:ok, _} = Registry.register(NodeRegistry.Invocations, id, {:invocation, node.id})
        recipient = Keyword.fetch!(opts, :recipient)

        state = %{
          id: id,
          node: node,
          method: method,
          run_id: run_id(method, args, id),
          recipient: recipient,
          recipient_ref: Process.monitor(recipient),
          node_ref: Process.monitor(node.pid),
          timer_ref: Process.send_after(self(), :timeout, timeout_ms),
          latest_event_seq: 0,
          max_payload_bytes: max_bytes,
          controls: %{}
        }

        send(node.pid, {:node_event, "node.invoke.request", payload})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:invalid_payload, reason}}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :private_node_transport)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  @impl true
  def handle_call({:event, node_id, pid, generation, seq, event}, _from, state) do
    with :ok <- session(state, node_id, pid, generation),
         :ok <- native(state),
         :ok <- validate_event(seq, event) do
      cond do
        seq <= state.latest_event_seq ->
          {:reply, {:ok, :duplicate}, state}

        seq == state.latest_event_seq + 1 ->
          send(state.recipient, {:lemon_node_event, state.id, seq, event})
          {:reply, {:ok, :accepted}, %{state | latest_event_seq: seq}}

        true ->
          {:reply, {:error, :sequence_gap}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:shell_event, node_id, pid, generation, payload}, _from, state) do
    with :ok <- session(state, node_id, pid, generation),
         true <- state.method == "node.shell.open",
         {:ok, _} <- JSONPayload.validate(payload, max_bytes: 32_768) do
      case Process.info(state.recipient, :message_queue_len) do
        {:message_queue_len, length} when length < 128 ->
          send(state.recipient, {:lemon_node_shell_event, state.id, payload})
          {:reply, :ok, state}

        _ ->
          {:reply, {:error, :slow_consumer}, state}
      end
    else
      {:error, reason} when reason in [:wrong_node, :stale_session] ->
        {:reply, {:error, :stale_invocation}, state}

      false ->
        {:reply, {:error, :stale_invocation}, state}

      _ ->
        {:reply, {:error, :invalid_payload}, state}
    end
  end

  def handle_call({:complete, node_id, result, error}, _from, state) do
    if node_id == state.node.id do
      complete(state, result, error)
    else
      {:reply, {:error, :wrong_node}, state}
    end
  end

  def handle_call({:complete_session, node_id, pid, generation, result, error}, _from, state) do
    case session(state, node_id, pid, generation) do
      :ok -> complete(state, result, error)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, reason}, _from, state) do
    cancel_remote(state, reason)
    finish(state, {:error, reason}, :terminal)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:disconnect, reason}, _from, state) do
    result = {:error, {:node_disconnected, reason}}
    cancel_remote(state, {:node_disconnected, reason})
    finish(state, result, {:node_disconnected, reason})
    {:stop, :normal, :ok, state}
  end

  def handle_call({:control, operation, text, recipient, timeout_ms}, _from, state) do
    with :ok <- validate_control(operation, text, recipient, timeout_ms),
         :ok <- native(state),
         {:ok, node} <- live_node(state) do
      id = LemonCore.Id.uuid()

      payload = %{
        "controlId" => id,
        "invokeId" => state.id,
        "runId" => state.run_id,
        "nodeId" => node.id,
        "nodeName" => node.name,
        "operation" => Atom.to_string(operation),
        "text" => text,
        "timeoutMs" => timeout_ms
      }

      case JSONPayload.validate(payload, max_bytes: state.max_payload_bytes) do
        {:ok, _} ->
          {:ok, _} =
            Registry.register(NodeRegistry.Invocations, {:control, id}, {:control, state.id})

          control = %{
            id: id,
            recipient: recipient,
            recipient_ref: Process.monitor(recipient),
            timer_ref: Process.send_after(self(), {:control_timeout, id}, timeout_ms)
          }

          send(node.pid, {:node_event, "node.invoke.control", payload})
          {:reply, {:ok, id}, %{state | controls: Map.put(state.controls, id, control)}}

        {:error, reason} ->
          {:reply, {:error, {:invalid_payload, reason}}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:control_result, node_id, pid, generation, control_id, invoke_id, run_id, accepted,
         reason},
        _from,
        state
      ) do
    case Map.fetch(state.controls, control_id) do
      {:ok, control} ->
        cond do
          node_id != state.node.id ->
            {:reply, {:error, :wrong_node}, state}

          invoke_id != state.id ->
            {:reply, {:error, :wrong_invocation}, state}

          run_id != state.run_id ->
            {:reply, {:error, :wrong_run}, state}

          true ->
            case session(state, node_id, pid, generation) do
              :ok ->
                result = if accepted, do: :ok, else: {:error, {:rejected, reason || "rejected"}}
                {:reply, :ok, finish_control(state, control, result)}

              error ->
                {:reply, error, state}
            end
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:approval, approval_id, decision}, {caller, _}, state) do
    with :ok <- native(state),
         true <- caller == state.recipient,
         :ok <- validate_approval(approval_id, decision),
         {:ok, node} <- live_node(state) do
      payload = %{
        "nodeId" => node.id,
        "invokeId" => state.id,
        "runId" => state.run_id,
        "approvalId" => approval_id,
        "decision" => decision
      }

      case JSONPayload.validate(payload, max_bytes: @max_event_bytes) do
        {:ok, _} ->
          send(node.pid, {:node_event, "node.invoke.approval", payload})
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, {:invalid_payload, payload_error_kind(reason)}}, state}
      end
    else
      false -> {:reply, {:error, :forbidden}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    cancel_remote(state, :timeout)
    finish(state, {:error, :timeout}, :terminal)
    {:stop, :normal, state}
  end

  def handle_info({:control_timeout, id}, state) do
    case Map.fetch(state.controls, id) do
      {:ok, control} -> {:noreply, finish_control(state, control, {:error, :timeout})}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{node_ref: ref} = state) do
    finish(
      state,
      {:error, {:node_disconnected, :disconnected}},
      {:node_disconnected, :disconnected}
    )

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{recipient_ref: ref} = state) do
    cancel_remote(state, :recipient_down)
    finish_controls(state, :recipient_down)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    controls =
      Enum.reduce(state.controls, state.controls, fn {id, control}, acc ->
        if control.recipient_ref == ref do
          cleanup_control(control)
          Map.delete(acc, id)
        else
          acc
        end
      end)

    {:noreply, %{state | controls: controls}}
  end

  @impl true
  def terminate(_reason, state) do
    Process.cancel_timer(state.timer_ref)
    Process.demonitor(state.recipient_ref, [:flush])
    Process.demonitor(state.node_ref, [:flush])
    Enum.each(state.controls, fn {_, control} -> cleanup_control(control) end)
  end

  defp complete(state, result, error) do
    opts =
      if state.method == "node.mcp.discover",
        do:
          LemonCore.ToolPolicy.execution_json_opts(
            max_bytes: min(state.max_payload_bytes, 1_048_576)
          ),
        else: json_opts(state.method, state.max_payload_bytes)

    case JSONPayload.validate(%{"result" => result, "error" => error}, opts) do
      {:ok, _} ->
        result = if is_nil(error), do: {:ok, result}, else: {:error, {:remote, error}}
        finish(state, result, :terminal)
        {:stop, :normal, :ok, state}

      {:error, reason} ->
        cancel_remote(state, {:invalid_payload, reason})
        finish(state, {:error, {:invalid_remote_payload, payload_error_kind(reason)}}, :terminal)
        {:stop, :normal, {:error, {:invalid_payload, reason}}, state}
    end
  end

  defp finish(state, result, control_reason) do
    Registry.unregister(NodeRegistry.Invocations, state.id)
    send(state.recipient, {:lemon_node_result, state.id, result})
    finish_controls(state, control_reason)
  end

  defp finish_controls(state, reason) do
    Registry.unregister(NodeRegistry.Invocations, state.id)

    Enum.each(state.controls, fn {_, control} ->
      Registry.unregister(NodeRegistry.Invocations, {:control, control.id})
      notify_control(state, control, {:error, reason})
    end)
  end

  defp finish_control(state, control, result) do
    cleanup_control(control)
    notify_control(state, control, result)
    %{state | controls: Map.delete(state.controls, control.id)}
  end

  defp notify_control(state, control, result) do
    send(control.recipient, {:lemon_node_control_result, control.id, state.id, result})
  end

  defp cleanup_control(control) do
    Registry.unregister(NodeRegistry.Invocations, {:control, control.id})
    Process.cancel_timer(control.timer_ref)
    Process.demonitor(control.recipient_ref, [:flush])
  end

  defp live_node(state) do
    case NodeRegistry.resolve_id(state.node.id) do
      {:ok, %{pid: pid, generation: generation} = node}
      when pid == state.node.pid and generation == state.node.generation ->
        {:ok, node}

      _ ->
        {:error, :node_offline}
    end
  end

  defp session(state, node_id, pid, generation) do
    cond do
      node_id != state.node.id ->
        {:error, :wrong_node}

      pid != state.node.pid or generation != state.node.generation ->
        {:error, :stale_session}

      true ->
        case live_node(state) do
          {:ok, _} -> :ok
          _ -> {:error, :stale_session}
        end
    end
  end

  defp cancel_remote(state, reason) do
    # Revocation raises the floor before removing the old socket. It must still
    # receive cancellation, but never redirect that cancellation to a successor.
    case Registry.lookup(NodeRegistry.Connections, state.node.id) do
      [{_owner, %{pid: pid, generation: generation} = node}]
      when pid == state.node.pid and generation == state.node.generation ->
        send(
          pid,
          {:node_event, "node.invoke.cancel",
           %{
             "invokeId" => state.id,
             "nodeId" => node.id,
             "nodeGeneration" => node.generation,
             "reason" => inspect(reason)
           }}
        )

      _ ->
        :ok
    end
  end

  defp native(%{method: "coding_agent.run", run_id: run_id})
       when is_binary(run_id) and run_id != "", do: :ok

  defp native(_), do: {:error, :unsupported}

  defp run_id("coding_agent.run", args, id) do
    case Map.get(args, "runId") || Map.get(args, :run_id) do
      run_id when is_binary(run_id) and run_id != "" -> run_id
      _ -> "node:#{id}"
    end
  end

  defp run_id(_, _, _), do: nil

  defp validate_control(operation, text, recipient, timeout_ms) do
    cond do
      operation not in [:steer, :redirect] ->
        {:error, :invalid_operation}

      not is_binary(text) or text == "" or not String.valid?(text) ->
        {:error, :invalid_text}

      byte_size(text) > @max_control_text_bytes ->
        {:error, {:text_too_large, @max_control_text_bytes}}

      not is_pid(recipient) ->
        {:error, :invalid_recipient}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:error, :invalid_timeout}

      true ->
        :ok
    end
  end

  defp validate_event(seq, event) do
    cond do
      not is_integer(seq) or seq <= 0 ->
        {:error, :invalid_seq}

      not is_map(event) or Map.get(event, "type") not in @event_types ->
        {:error, :invalid_event_type}

      true ->
        case JSONPayload.validate(event, max_bytes: @max_event_bytes) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:invalid_payload, payload_error_kind(reason)}}
        end
    end
  end

  defp validate_approval(id, decision) do
    cond do
      not is_binary(id) or String.trim(id) == "" -> {:error, :invalid_approval_id}
      decision not in @approval_decisions -> {:error, :invalid_decision}
      true -> :ok
    end
  end

  defp json_opts("coding_agent.run", max_bytes),
    do: LemonCore.ToolPolicy.execution_json_opts(max_bytes: max_bytes)

  defp json_opts(_, max_bytes), do: [max_bytes: max_bytes]

  defp payload_error_kind({kind, _})
       when kind in [:max_bytes, :max_depth, :max_items, :not_json_safe],
       do: kind

  defp payload_error_kind(_), do: :invalid
end
