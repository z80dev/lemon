defmodule LemonRouter.RestartCarryover.CrashRecovery do
  @moduledoc """
  Durable private restart descriptors and a bounded, content-free operator view.

  Descriptors are committed before dispatch, independently of the permanent,
  content-free admission fences. Boot recovery is serialized by RunOrchestrator;
  an uncertain mutation is never retried in the same boot. The three-attempt
  policy is shared with graceful carryover and counts before execution starts.
  """

  alias LemonCore.{ExecutionCommand, MapHelpers, ResumeToken, RunRequest, RunStore, Store}
  alias LemonRouter.{RestartCarryover, RunOrchestrator}

  @table :router_crash_recovery
  @max_attempts 3
  @max_view 100

  def table, do: @table
  def max_attempts, do: @max_attempts

  @doc false
  # `enabled?` is the `crash_resume` feature from the admission's config
  # snapshot (`LemonRouter.SubmissionBuilder.admission_settings/0`).
  def capture(%{request: %RunRequest{} = request, execution_request: command}, enabled?) do
    if enabled?, do: capture_resumable(request, command), else: :ok
  end

  defp capture_resumable(%RunRequest{} = request, command) do
    request = %RunRequest{
      request
      | cwd: command.cwd,
        resume: command.resume,
        tool_policy: command.tool_policy,
        meta: RunStore.execution_projection(request.meta || %{})
    }

    descriptor =
      case portable(request, command.meta || %{}) do
        {:ok, request} -> %{request: request, state: :ready}
        {:error, reason} -> %{state: :unresumable, reason: reason}
      end
      |> Map.put(:updated_at_ms, System.system_time(:millisecond))

    case Store.put_new(Store, @table, request.run_id, descriptor, durable: true) do
      :ok -> :ok
      {:error, :exists} -> :ok
      _ -> {:error, :outcome_unknown}
    end
  end

  defp portable(request, meta) do
    cond do
      MapHelpers.get_key(meta, :node) not in [nil, "", "local"] ->
        {:error, :remote_invocation}

      MapHelpers.get_key(meta, :invocation_proof_verified) == true or
          MapHelpers.get_key(meta, :mcp_servers) not in [nil, []] ->
        {:error, :invocation_bound}

      true ->
        RestartCarryover.portable_request(request)
    end
  end

  @doc false
  def bind_resume(run_id, %ResumeToken{engine: "lemon"} = resume) do
    case Store.fetch(@table, run_id) do
      {:ok, %{request: %RunRequest{} = request} = descriptor} ->
        command = %ExecutionCommand{
          run_id: run_id,
          session_key: request.session_key,
          prompt: request.prompt,
          meta: request.meta,
          tool_policy: request.tool_policy
        }

        with :ok <- LemonRouter.ResumeResolver.bind(resume, command),
             :ok <-
               Store.compare_and_swap(
                 Store,
                 @table,
                 run_id,
                 descriptor,
                 %{descriptor | request: %{request | resume: resume}},
                 durable: true
               ) do
          :ok
        end

      {:ok, _absent_or_unresumable} ->
        :ok

      _ ->
        {:error, :outcome_unknown}
    end
  end

  def bind_resume(_run_id, _resume), do: {:error, :invalid_resume}

  @doc false
  def continuation(run_id, attempt) do
    case Store.fetch(@table, run_id) do
      {:ok, %{request: %RunRequest{} = request}} ->
        with {:ok, calls} <- unknown_calls(request) do
          titles = Enum.map(calls, &"#{&1.name} (#{&1.id})")

          meta =
            request.meta
            |> Map.drop([:disable_auto_resume, "disable_auto_resume"])
            |> Map.merge(%{
              restart_continuation: true,
              crash_resume: true,
              restart_attempt: attempt
            })

          {:ok,
           %RunRequest{
             request
             | prompt: RestartCarryover.continue_prompt({:uncertain, titles}, request.prompt),
               images: [],
               queue_mode: :collect,
               meta: meta
           }}
        end

      {:ok, _} ->
        {:error, :unresumable}

      _ ->
        {:error, :unavailable}
    end
  end

  defp unknown_calls(%RunRequest{resume: nil}), do: {:ok, []}

  defp unknown_calls(%RunRequest{cwd: cwd, resume: resume}) do
    LemonCore.AgentRuntime.call(:interrupted_tool_calls, [cwd, resume], {:error, :unavailable})
  end

  @doc false
  def reconcile(admissions, opts \\ []) do
    abandon = Keyword.get(opts, :abandon, &RunOrchestrator.abandon_orphan/3)
    carried = carried_sources(Keyword.get(opts, :carryover, []))
    recover = Keyword.get(opts, :recover, &RunOrchestrator.recover_orphan/2)

    Enum.reduce(admissions, %{resumed: 0, abandoned: 0, skipped: 0, pending: 0}, fn
      {run_id, admission}, acc when is_binary(run_id) and is_map(admission) ->
        result =
          if MapSet.member?(carried, run_id),
            do: settle_orphan(fn -> abandon.(run_id, admission, :graceful_carryover) end),
            else: settle_orphan(fn -> recover.(run_id, admission) end)

        case result do
          {:ok, disposition} when disposition in [:resumed, :abandoned, :skipped] ->
            Map.update!(acc, disposition, &(&1 + 1))

          _ ->
            Map.update!(acc, :pending, &(&1 + 1))
        end

      _, acc ->
        acc
    end)
  end

  # A timed-out serialized call may still be applied for this fixed run ID. It
  # stays pending for the next boot; one slow admission never ends the boot's
  # recovery of the others.
  defp settle_orphan(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :outcome_unknown}
  end

  defp carried_sources(rows) do
    for {_key, %{items: items}} <- rows,
        %{interrupted_run_id: original, request: %RunRequest{run_id: carried}} <- items,
        is_binary(original) and original != carried,
        into: MapSet.new(),
        do: original
  end

  @doc false
  def settle(server, run_id) do
    case Store.fetch(server, @table, run_id) do
      {:ok, nil} ->
        :ok

      {:ok, %{state: :resumed, request: _request} = current} ->
        Store.put(server, @table, run_id, Map.delete(current, :request), durable: true)

      {:ok, %{state: :resumed}} ->
        :ok

      {:ok, %{state: :abandoned}} ->
        :ok

      {:ok, _} ->
        Store.delete(server, @table, run_id, durable: true)

      error ->
        error
    end
  end

  @doc false
  def record(run_id, state, reason, attempts) do
    replacement = %{
      state: state,
      reason: reason,
      attempts: attempts,
      updated_at_ms: System.system_time(:millisecond)
    }

    with {:ok, current} <- Store.fetch(@table, run_id) do
      descriptor =
        if state == :resumed and is_map(current),
          do: Map.merge(current, replacement),
          else: replacement

      Store.put(Store, @table, run_id, descriptor, durable: true)
    end
  end

  @doc "Return at most 100 recent recovery decisions, without prompts, paths or tool arguments."
  def operator_view(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(0) |> min(@max_view)

    with {:ok, rows} <- Store.fetch_all(@table) do
      entries =
        rows
        |> Enum.filter(fn {_id, row} -> row[:state] in [:resumed, :abandoned] end)
        |> Enum.sort_by(fn {id, row} -> {-row.updated_at_ms, id} end)
        |> Enum.take(limit)
        |> Enum.map(fn {id, row} ->
          row |> Map.take([:state, :reason, :attempts, :updated_at_ms]) |> Map.put(:run_id, id)
        end)

      {:ok, entries}
    end
  end
end
