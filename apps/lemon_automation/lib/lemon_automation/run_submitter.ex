defmodule LemonAutomation.RunSubmitter do
  @moduledoc false

  alias LemonAutomation.{CronJob, CronMemory, CronRun, RunCompletionWaiter}
  alias LemonCore.{Bus, SessionKey}

  @default_timeout_ms 300_000

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, binary()} | :timeout
  def submit(%CronJob{} = job, %CronRun{} = run, opts \\ []) do
    timeout_ms = job.timeout_ms || @default_timeout_ms
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    wait_opts = Keyword.get(opts, :wait_opts, [])

    # Pre-generate run_id and subscribe to bus BEFORE submitting to avoid
    # race condition where run completes before we subscribe
    run_id = LemonCore.Id.run_id()
    topic = Bus.run_topic(run_id)
    Bus.subscribe(topic)

    params = build_params(job, run, run_id, opts)
    memory_mod = Keyword.get(opts, :memory_mod, CronMemory)

    result =
      try do
        case router_mod.submit(params) do
          {:ok, ^run_id} ->
            # Already subscribed above, just wait for completion
            waiter_mod.wait_already_subscribed(run_id, timeout_ms, wait_opts)

          {:ok, other_run_id} ->
            # Router used a different run_id than expected
            Bus.unsubscribe(topic)
            waiter_mod.wait(other_run_id, timeout_ms, wait_opts)

          {:error, reason} ->
            Bus.unsubscribe(topic)
            {:error, inspect(reason)}

          other ->
            Bus.unsubscribe(topic)
            {:error, "Unexpected submit result: #{inspect(other)}"}
        end
      rescue
        e ->
          Bus.unsubscribe(topic)
          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          Bus.unsubscribe(topic)
          {:error, "Exit: #{inspect(reason)}"}
      end

    _ = append_memory(memory_mod, job, run, params, result)
    result
  end

  @doc false
  @spec build_params(CronJob.t(), CronRun.t(), binary() | nil, keyword()) :: map()
  def build_params(%CronJob{} = job, %CronRun{} = run, run_id \\ nil, opts \\ []) do
    memory_mod = Keyword.get(opts, :memory_mod, CronMemory)
    session_key = fork_session_key(job.session_key, job.agent_id)
    {memory_file, memory_context} = read_memory(memory_mod, job)
    prompt = build_prompt(memory_mod, job.prompt, memory_file, memory_context)

    params = %{
      origin: :cron,
      session_key: session_key,
      prompt: prompt,
      agent_id: job.agent_id,
      meta: %{
        cron_job_id: job.id,
        cron_run_id: run.id,
        triggered_by: run.triggered_by,
        cron_base_session_key: job.session_key,
        cron_memory_file: memory_file
      }
    }

    # Include run_id if provided so router uses it instead of generating new one
    if run_id do
      Map.put(params, :run_id, run_id)
    else
      params
    end
  end

  defp fork_session_key(session_key, agent_id) when is_binary(agent_id) do
    sub_id = new_sub_id()

    case SessionKey.parse(session_key || "") do
      %{kind: :main, agent_id: parsed_agent_id} ->
        "agent:#{parsed_agent_id || agent_id}:main:sub:#{sub_id}"

      %{
        kind: :channel_peer,
        agent_id: parsed_agent_id,
        channel_id: channel_id,
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: thread_id
      } ->
        SessionKey.channel_peer(%{
          agent_id: parsed_agent_id || agent_id,
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: peer_kind,
          peer_id: peer_id,
          thread_id: thread_id,
          sub_id: sub_id
        })

      _ ->
        "agent:#{agent_id}:main:sub:#{sub_id}"
    end
  rescue
    _ -> "agent:#{agent_id}:main:sub:#{new_sub_id()}"
  end

  defp read_memory(memory_mod, job) do
    if function_exported?(memory_mod, :read_for_prompt, 1) do
      memory_mod.read_for_prompt(job)
    else
      {CronMemory.memory_file(job), nil}
    end
  rescue
    _ -> {CronMemory.memory_file(job), nil}
  end

  defp build_prompt(memory_mod, prompt, memory_file, memory_context) do
    if function_exported?(memory_mod, :build_prompt, 3) do
      memory_mod.build_prompt(prompt, memory_file, memory_context)
    else
      prompt
    end
  rescue
    _ -> prompt
  end

  defp append_memory(memory_mod, job, run, params, result) do
    if function_exported?(memory_mod, :append_run, 4) do
      run_with_router_id =
        if is_nil(run.run_id) and is_binary(params[:run_id]) do
          %{run | run_id: params[:run_id]}
        else
          run
        end

      memory_mod.append_run(job, run_with_router_id, params.session_key, result)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp new_sub_id do
    LemonCore.Id.session_id()
    |> String.replace_prefix("sess_", "cron_")
  rescue
    _ -> "cron_#{System.unique_integer([:positive])}"
  end
end
