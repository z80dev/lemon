defmodule LemonAutomation.RunSubmitter do
  @moduledoc false

  alias LemonAutomation.{CronContext, CronJob, CronMemory, CronRun, RunCompletionWaiter}
  alias LemonCore.SessionKey

  @default_timeout_ms 300_000
  @cron_blocked_tools ["cron"]

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, binary()} | :timeout
  def submit(%CronJob{} = job, %CronRun{} = run, opts \\ []) do
    timeout_ms = job.timeout_ms || @default_timeout_ms
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    wait_opts = Keyword.get(opts, :wait_opts, [])

    run_id = Keyword.get(opts, :run_id, LemonCore.Id.run_id())
    params = build_params(job, run, run_id, opts)
    memory_mod = Keyword.get(opts, :memory_mod, CronMemory)

    result =
      params
      |> RunCompletionWaiter.submit_and_wait(
        router_mod: router_mod,
        waiter_mod: waiter_mod,
        bus_mod: Keyword.get(opts, :bus_mod, LemonCore.Bus),
        timeout_ms: timeout_ms,
        wait_opts: wait_opts
      )
      |> normalize_submit_result()

    _ = append_memory(memory_mod, job, run, params, result)
    result
  end

  defp normalize_submit_result({:ok, _run_id, output}), do: {:ok, output}
  defp normalize_submit_result({:error, {:timeout, _run_id}}), do: :timeout

  defp normalize_submit_result({:error, {:run_failed, _run_id, reason}}),
    do: {:error, inspect(reason)}

  defp normalize_submit_result({:error, {:submit_failed, {:exception, error}}}),
    do: {:error, Exception.message(error)}

  defp normalize_submit_result({:error, {:submit_failed, {:exit, reason}}}),
    do: {:error, "Exit: #{inspect(reason)}"}

  defp normalize_submit_result({:error, {:submit_failed, {:unexpected_submit_result, other}}}),
    do: {:error, "Unexpected submit result: #{inspect(other)}"}

  defp normalize_submit_result({:error, {:submit_failed, reason}}), do: {:error, inspect(reason)}
  defp normalize_submit_result({:error, reason}), do: {:error, inspect(reason)}

  @doc false
  @spec build_params(CronJob.t(), CronRun.t(), binary() | nil, keyword()) :: map()
  def build_params(%CronJob{} = job, %CronRun{} = run, run_id \\ nil, opts \\ []) do
    memory_mod = Keyword.get(opts, :memory_mod, CronMemory)
    context_mod = Keyword.get(opts, :context_mod, CronContext)
    session_key = fork_session_key(job.session_key, job.agent_id)
    {memory_file, memory_context} = read_memory(memory_mod, job)
    base_prompt = context_mod.augment_prompt(job, job.prompt)
    prompt = build_prompt(memory_mod, base_prompt, memory_file, memory_context)

    params = %{
      origin: :cron,
      session_key: session_key,
      prompt: prompt,
      agent_id: job.agent_id,
      tool_policy: cron_tool_policy(),
      meta: %{
        cron_job_id: job.id,
        cron_run_id: run.id,
        cron_router_run_id: run_id,
        triggered_by: run.triggered_by,
        cron_base_session_key: job.session_key,
        cron_session_key: session_key,
        cron_agent_id: job.agent_id,
        cron_memory_file: memory_file
      }
    }

    params = maybe_pin_model(params, job)

    # Include run_id if provided so router uses it instead of generating new one
    if run_id do
      Map.put(params, :run_id, run_id)
    else
      params
    end
  end

  # An explicit job model pin overrides the global default for this run;
  # `LemonCore.RunRequest.normalize/1` carries `:model` through to the engine.
  defp maybe_pin_model(params, %CronJob{model: model})
       when is_binary(model) do
    if String.trim(model) == "" do
      params
    else
      params
      |> Map.put(:model, model)
      |> Map.update!(:meta, &Map.put(&1, :cron_model_pin, model))
    end
  end

  defp maybe_pin_model(params, _job), do: params

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

  defp cron_tool_policy do
    %{
      blocked_tools: @cron_blocked_tools
    }
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
