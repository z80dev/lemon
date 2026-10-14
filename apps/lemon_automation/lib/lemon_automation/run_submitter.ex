defmodule LemonAutomation.RunSubmitter do
  @moduledoc false

  alias LemonAutomation.{CronAdmission, CronContext, CronJob, CronMemory, CronRun, RunCompletionWaiter}
  alias LemonCore.{SessionKey, ToolPolicy}

  @default_timeout_ms 300_000
  @cron_blocked_tools ["cron"]

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, term()} | :timeout
  def submit(%CronJob{} = job, %CronRun{} = run, opts \\ []) do

    run_id = Keyword.get(opts, :run_id) || run.run_id || LemonCore.Id.run_id()
    case build_params(job, run, run_id, opts) do
      {:error, _} = error -> error
      params -> submit_params(job, run, run_id, params, opts)
    end
  end

  defp submit_params(job, run, run_id, params, opts) do
    timeout_ms = job.timeout_ms || @default_timeout_ms
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    wait_opts = Keyword.get(opts, :wait_opts, [])
    memory_mod = Keyword.get(opts, :memory_mod, CronMemory)

    result =
      params
      |> RunCompletionWaiter.submit_and_wait(
        router_mod: router_mod,
        waiter_mod: waiter_mod,
        bus_mod: Keyword.get(opts, :bus_mod, LemonCore.Bus),
        timeout_ms: timeout_ms,
        wait_opts: wait_opts,
        on_submitting: fn fixed_id ->
          with :ok <- LemonAutomation.RunNotifications.bind_cron(job, params) do
            case Keyword.get(opts, :on_submitting) do
              nil -> :ok
              callback -> callback.(fixed_id, params.session_key)
            end
          end
        end
      )
      |> normalize_submit_result(run_id)

    if Keyword.get(opts, :append_memory, true) do
      _ = append_memory(memory_mod, job, run, params, result)
    end

    result
  end

  defp normalize_submit_result({:error, {:submit_failed, {kind, _}}}, run_id)
       when kind in [:exception, :exit, :unexpected_submit_result],
       do: {:error, {:outcome_unknown, run_id}}

  defp normalize_submit_result(result, _run_id), do: normalize_submit_result(result)

  defp normalize_submit_result({:ok, _run_id, output}), do: {:ok, output}

  defp normalize_submit_result({:error, {kind, run_id}})
       when kind in [:completion_outcome_unknown, :submission_outcome_unknown, :timeout],
       do: {:error, {:outcome_unknown, run_id}}

  defp normalize_submit_result({:error, {:unexpected_run_id, run_id, _other}}),
    do: {:error, {:outcome_unknown, run_id}}

  defp normalize_submit_result({:error, {:run_failed, _run_id, reason}}),
    do: {:error, inspect(reason)}

  defp normalize_submit_result({:error, {:submit_failed, reason}}), do: {:error, inspect(reason)}
  defp normalize_submit_result({:error, reason}), do: {:error, inspect(reason)}

  @doc false
  @spec build_params(CronJob.t(), CronRun.t(), binary() | nil, keyword()) ::
          map() | {:error, term()}
  def build_params(%CronJob{} = job, %CronRun{} = run, run_id \\ nil, opts \\ []) do
    with {:ok, invocation} <- admission_invocation(job, opts) do
      do_build_params(job, run, run_id, opts, invocation)
    end
  end

  defp do_build_params(job, run, run_id, opts, invocation) do
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
      cwd: job.cwd,
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

    params = apply_invocation(params, invocation)

    case apply_profile(params, job, run_id, invocation) do
      {:error, _} = error ->
        error

      params ->
        params = maybe_pin_model(params, job)
        if run_id, do: Map.put(params, :run_id, run_id), else: params
    end
  end

  defp admission_invocation(job, opts) do
    case Keyword.fetch(opts, :admission_invocation) do
      :error ->
        {:ok, nil}

      {:ok, %{context_key: key, mcp_servers: servers, tool_policy: policy} = projection}
      when map_size(projection) == 3 ->
        with false <- is_nil(job.admission),
             true <- is_binary(job.profile_id),
             :agent <- CronJob.execution_mode(job),
             {:ok, ^projection} <-
               CronAdmission.validate_invocation(%{
                 "invocationContextKey" => key,
                 "invocationMcpServers" => servers,
                 "invocationToolPolicy" => policy
               }) do
          {:ok, projection}
        else
          _ -> {:error, :admission_unavailable}
        end

      {:ok, _} ->
        {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  defp apply_invocation(params, nil), do: params

  defp apply_invocation(params, invocation) do
    params
    |> Map.put(:tool_policy, ToolPolicy.intersect(params.tool_policy, invocation.tool_policy))
    |> Map.update!(:meta, &Map.put(&1, :invocation_context_key, invocation.context_key))
  end

  defp apply_profile(params, %CronJob{profile_id: nil}, _run_id, _invocation), do: params

  defp apply_profile(params, %CronJob{profile_id: profile_id, cwd: cwd}, run_id, invocation) do
    case LemonCore.ProfileStore.get_for_execution(profile_id) do
      {:ok, profile} ->
        opts = [
          session_key: params.session_key,
          run_id: run_id,
          cwd: cwd,
          origin: :cron,
          tool_policy: params.tool_policy,
          meta: params.meta
        ]

        opts =
          if is_nil(invocation),
            do: opts,
            else: Keyword.put(opts, :invocation_mcp_servers, invocation.mcp_servers)

        case LemonCore.ProfileStore.chat_request(profile, params.prompt, opts) do
          {:ok, request} -> Map.from_struct(request)
          {:error, _} -> {:error, :invalid_profile_request}
        end

      {:error, :not_found} ->
        {:error, :unknown_profile}

      {:error, _} ->
        {:error, :profile_unavailable}
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

  defp append_memory(_memory_mod, _job, _run, _params, {:error, {:outcome_unknown, _}}),
    do: :ok

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
