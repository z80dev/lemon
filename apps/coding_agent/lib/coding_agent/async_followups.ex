defmodule CodingAgent.AsyncFollowups do
  @moduledoc """
  Owns completion delivery for native and delegated children.

  Compatible completions share a fixed 50 ms window starting at the first
  arrival, not a sliding debounce. This caller policy coalesces completion bursts
  while bounding added latency; it is not a measured provider latency optimum.
  Parent identity, delivery mode and execution authority must all match.
  """

  use GenServer
  require Logger

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Params
  alias LemonCore.{Bus, RunRequest, SessionKey}

  @completion_batch_window_ms 50
  @context_keys [
    :parent_session_key,
    :parent_agent_id,
    :session_module,
    :session_pid,
    :queue_mode,
    :run_orchestrator,
    :cwd,
    :tool_policy,
    :meta,
    :invocation_context_key,
    :invocation_mcp_servers,
    :native_managed_context,
    :native_lineage_run_id,
    :native_lineage_handle,
    :native_followup_submit
  ]
  @completion_meta_keys ~w(
    task_auto_followup task_id run_id delegated_auto_followup delegated_run_id
    delegated_task_id delegated_agent_id delegated_session_key async_followups
  )a
  @completion_meta_keys @completion_meta_keys ++
                          Enum.map(@completion_meta_keys, &Atom.to_string/1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def enqueue(context, text, entry, server \\ __MODULE__) do
    context = normalize_context(context)
    GenServer.call(server, {:enqueue, context, {text, entry}})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       batches: %{},
       deferred: %{},
       window_ms: Keyword.get(opts, :window_ms, @completion_batch_window_ms),
       schedule_flush: Keyword.get(opts, :schedule_flush, &Process.send_after/3),
       task_supervisor: Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:enqueue, context, completion}, _from, state) do
    {:reply, :ok, accept_completion(state, context, completion)}
  end

  @impl true
  def handle_info({:flush, context, token}, state) do
    case Map.get(state.batches, context) do
      %{token: ^token, completions: completions} ->
        state = %{state | batches: Map.delete(state.batches, context)}

        {ready, state} =
          Enum.reduce(Enum.reverse(completions), {[], state}, fn completion, {ready, state} ->
            case hold_completion(state, context, completion) do
              {:ready, state} -> {[completion | ready], state}
              {:held, state} -> {ready, state}
            end
          end)

        if ready != [] do
          case Task.Supervisor.start_child(state.task_supervisor, fn ->
                 deliver(context, Enum.reverse(ready))
               end) do
            {:ok, _pid} -> :ok
            {:error, reason} -> log_failure(reason)
          end
        end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:task_state, :changed, task_id}, state) do
    {completions, deferred} = Map.pop(state.deferred, task_id, [])
    state = %{state | deferred: deferred}
    Bus.unsubscribe("task_state:#{task_id}")

    state =
      Enum.reduce(Enum.reverse(completions), state, fn {context, completion}, state ->
        accept_completion(state, context, completion)
      end)

    {:noreply, state}
  end

  defp accept_completion(state, context, completion) do
    case hold_completion(state, context, completion) do
      {:held, state} ->
        state

      {:ready, state} ->
        batches =
          case Map.get(state.batches, context) do
            nil ->
              token = make_ref()
              state.schedule_flush.(self(), {:flush, context, token}, state.window_ms)
              Map.put(state.batches, context, %{token: token, completions: [completion]})

            batch ->
              Map.put(state.batches, context, %{
                batch
                | completions: [completion | batch.completions]
              })
          end

        %{state | batches: batches}
    end
  end

  defp hold_completion(state, context, {_text, %{task_id: task_id}} = completion)
       when is_binary(task_id) and task_id != "" do
    # Subscribe before reading: a join finishing between these operations must
    # release its losing completions without a poll or another task event.
    already_deferred? = Map.has_key?(state.deferred, task_id)
    unless already_deferred?, do: Bus.subscribe("task_state:#{task_id}")

    record =
      case TaskStore.get_record(task_id) do
        {:ok, record} -> record
        {:error, :not_found} -> %{}
      end

    cond do
      not is_nil(record[:auto_followup_suppressed_at]) ->
        unless already_deferred?, do: Bus.unsubscribe("task_state:#{task_id}")
        {:held, state}

      Map.get(record, :auto_followup_join_tokens, []) != [] ->
        deferred =
          Map.update(state.deferred, task_id, [{context, completion}], fn pending ->
            [{context, completion} | pending]
          end)

        {:held, %{state | deferred: deferred}}

      true ->
        unless already_deferred?, do: Bus.unsubscribe("task_state:#{task_id}")
        {:ready, state}
    end
  end

  defp hold_completion(state, _context, _completion), do: {:ready, state}

  defp normalize_context(context) do
    managed? = Params.managed_context?(context)

    queue_mode =
      case Map.get(context, :queue_mode, :followup) do
        _ when managed? -> :collect
        mode when mode in [:steer, :steer_backlog] -> :followup
        mode -> mode
      end

    meta =
      context
      |> Map.get(:meta, %{})
      |> Params.continuation_metadata(context)
      |> Map.drop(@completion_meta_keys)

    @context_keys
    |> Map.new(&{&1, Map.get(context, &1)})
    |> Map.put(:session_module, Map.get(context, :session_module, CodingAgent.Session))
    |> Map.put(:session_pid, Map.get(context, :session_pid))
    |> Map.put(:queue_mode, queue_mode)
    |> Map.put(:native_managed_context, managed?)
    |> Map.put(:meta, meta)
    |> Map.put(
      :run_orchestrator,
      Map.get(
        context,
        :run_orchestrator,
        CodingAgent.Tools.Task.Followup.default_run_orchestrator()
      )
    )
  end

  defp deliver(context, completions) do
    target =
      if context.native_managed_context,
        do: {:router, :collect},
        else: dispatch_target(context.queue_mode, context.session_module, context.session_pid)

    text = Enum.map_join(completions, "\n\n", &elem(&1, 0))

    entries =
      Enum.map(completions, fn {_text, entry} ->
        Map.put(entry, :delivery, elem(target, 1))
      end)

    case target do
      {:live, :followup} ->
        message = %{
          content: text,
          details: if(match?([_], entries), do: hd(entries), else: %{delivery: :followup}),
          async_followups: entries
        }

        unless send_live(context, message), do: submit_router(context, text, entries)

      {:router, _mode} ->
        submit_router(context, text, entries)
    end
  rescue
    error -> log_failure({:exception, error})
  catch
    kind, reason -> log_failure({kind, reason})
  end

  defp send_live(context, message) do
    case context.session_module.handle_async_followup(context.session_pid, message) do
      {:error, _reason} -> false
      _ -> true
    end
  rescue
    _ -> false
  catch
    # A dead session is a definite pre-delivery failure. A timed-out call may
    # already have queued the batch, so it must not also submit through router.
    :exit, {:noproc, _} -> false
    :exit, {:normal, _} -> false
  end

  defp submit_router(context, text, entries) do
    session_key = context[:parent_session_key]

    if is_binary(session_key) and session_key != "" do
      agent_id = context[:parent_agent_id] || SessionKey.agent_id(session_key) || "default"

      meta =
        context.meta
        |> Map.merge(completion_metadata(entries))
        |> Map.put("async_followups", entries)

      request =
        RunRequest.new(%{
          run_id: LemonCore.Id.run_id(),
          origin: :node,
          session_key: session_key,
          agent_id: agent_id,
          prompt: text,
          queue_mode: context.queue_mode,
          cwd: context[:cwd],
          tool_policy: context[:tool_policy],
          meta: meta
        })

      case submit(context, request) do
        {:ok, _run_id} ->
          :ok

        {:error, {:unknown_agent_id, _}}
        when agent_id != "default" and not context.native_managed_context ->
          case submit(context, %{request | agent_id: "default"}) do
            {:ok, _run_id} -> :ok
            error -> log_failure(error)
          end

        error ->
          log_failure(error)
      end
    else
      Logger.debug("Skipping async completion: parent session key unavailable")
    end
  end

  defp submit(%{native_managed_context: true} = context, request) do
    Params.submit_native_followup(context, %{
      request
      | meta: LemonCore.RunStore.execution_projection(request.meta)
    })
  end

  defp submit(context, request) do
    router = context.run_orchestrator

    cond do
      function_exported?(router, :submit_run, 1) -> router.submit_run(request)
      function_exported?(router, :submit, 1) -> router.submit(request)
      true -> {:error, :unavailable}
    end
  end

  defp completion_metadata([%{source: :task} = entry]) do
    %{task_auto_followup: true, task_id: entry.task_id, run_id: entry.run_id}
  end

  defp completion_metadata([%{source: :agent} = entry]) do
    %{
      delegated_auto_followup: true,
      delegated_run_id: entry.run_id,
      delegated_task_id: entry.task_id,
      delegated_agent_id: entry.agent_id,
      delegated_session_key: entry.session_key
    }
  end

  defp completion_metadata(entries) do
    Enum.reduce(entries, %{}, fn
      %{source: :task}, meta -> Map.put(meta, :task_auto_followup, true)
      %{source: :agent}, meta -> Map.put(meta, :delegated_auto_followup, true)
    end)
  end

  defp log_failure(reason) do
    Logger.warning("Async completion followup delivery failed: #{inspect(reason)}")
  end

  @type queue_mode :: :collect | :followup | :interrupt | :steer | :steer_backlog
  @valid_queue_modes [:collect, :followup, :interrupt, :steer, :steer_backlog]

  @spec resolve_async_followup_queue_mode(queue_mode() | nil, queue_mode()) :: queue_mode()
  def resolve_async_followup_queue_mode(tool_queue_mode, fallback \\ :followup) do
    cond do
      not is_nil(tool_queue_mode) ->
        tool_queue_mode

      true ->
        configured_default_queue_mode() || fallback
    end
  end

  @spec dispatch_target(queue_mode(), module(), pid() | nil) ::
          {:live, :followup} | {:router, queue_mode()}
  def dispatch_target(queue_mode, session_module, session_pid) do
    cond do
      queue_mode in [:followup, :steer, :steer_backlog] and
          live_session_available?(session_module, session_pid) ->
        {:live, :followup}

      queue_mode in [:steer, :steer_backlog] ->
        {:router, :followup}

      true ->
        {:router, queue_mode}
    end
  end

  @spec live_session_available?(module(), pid() | nil) :: boolean()
  def live_session_available?(session_module, session_pid) do
    is_pid(session_pid) and Process.alive?(session_pid) and
      function_exported?(session_module, :handle_async_followup, 2)
  end

  defp configured_default_queue_mode do
    case Application.get_env(:coding_agent, :async_followups, []) do
      config when is_map(config) ->
        normalize_queue_mode(
          Map.get(config, :default_queue_mode) || Map.get(config, "default_queue_mode")
        )

      config when is_list(config) ->
        normalize_queue_mode(Keyword.get(config, :default_queue_mode))

      _other ->
        nil
    end
  end

  defp normalize_queue_mode(queue_mode) when queue_mode in @valid_queue_modes, do: queue_mode

  defp normalize_queue_mode(queue_mode) when is_binary(queue_mode) do
    case String.trim(queue_mode) do
      "collect" -> :collect
      "followup" -> :followup
      "interrupt" -> :interrupt
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      _ -> nil
    end
  end

  defp normalize_queue_mode(_queue_mode), do: nil
end
