defmodule LemonRouter.RunOrchestrator do
  @moduledoc """
  Orchestrates run submission and lifecycle.

  The orchestrator is responsible for:
  - Normalizing router-facing `RunRequest` input
  - Recording orchestration lifecycle introspection
  - Building a router-owned `Submission` plus gateway `ExecutionRequest`
  - Delegating run-start mechanics to `LemonRouter.RunStarter`
  - Subscribing external event bridges before coordinator handoff
  """

  use GenServer

  require Logger

  alias LemonCore.{Introspection, MapHelpers, RunRequest, SessionKey}
  alias LemonRouter.{RunProcess, RunStarter, SessionCoordinator, Submission, SubmissionBuilder}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a run request.

  ## Parameters

  Accepts a `%LemonCore.RunRequest{}` with these fields:

  - `:origin` - Source of the request (:channel, :control_plane, :cron, :node)
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier
  - `:prompt` - User prompt text
  - `:queue_mode` - Queue mode (:collect, :followup, :steer, :steer_backlog, :interrupt)
  - `:engine_id` - Optional engine override
  - `:model` - Optional model override (independent of profile binding)
  - `:meta` - Additional metadata
  - `:cwd` - Optional cwd override
  - `:tool_policy` - Optional tool policy override

  ## Returns

  `{:ok, run_id}` on success, `{:error, reason}` on failure.
  """
  @spec submit(RunRequest.t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = request), do: submit(__MODULE__, request)

  def submit(request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(__MODULE__, normalized)
  end

  @doc """
  Submit a run request to a specific orchestrator server.
  """
  @spec submit(GenServer.server(), RunRequest.t() | map() | keyword()) ::
          {:ok, binary()} | {:error, term()}
  def submit(server, %RunRequest{} = request), do: GenServer.call(server, {:submit, request})

  def submit(server, request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(server, normalized)
  end

  @doc """
  Start a run process from a prepared submission.

  This entrypoint is used by `LemonRouter.SessionCoordinator`, which owns
  queue semantics and decides when a submission should become an active run.
  Orchestrator defaults fill only missing start fields; caller-supplied
  `run_supervisor`, `run_process_module`, and `run_process_opts` are preserved.
  """
  @spec start_run_process(GenServer.server(), Submission.t() | map(), pid(), term()) ::
          {:ok, pid()} | {:error, term()}
  def start_run_process(server, submission, coordinator_pid, conversation_key)
      when is_map(submission) and is_pid(coordinator_pid) do
    GenServer.call(
      server,
      {:start_run_process, submission, coordinator_pid, conversation_key},
      15_000
    )
  end

  @doc """
  Lightweight run counts for status UIs.

  `active` reflects current supervised run processes.
  `queued` and `completed_today` are derived from telemetry counters
  maintained by `LemonRouter.RunCountTracker`.
  """
  @spec counts() :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          completed_today: non_neg_integer()
        }
  def counts do
    active =
      try do
        %{active: n} = DynamicSupervisor.count_children(LemonRouter.RunSupervisor)
        n
      rescue
        _ -> 0
      end

    {queued, completed_today} =
      try do
        {LemonRouter.RunCountTracker.queued(), LemonRouter.RunCountTracker.completed_today()}
      rescue
        _ -> {0, 0}
      end

    %{active: active, queued: queued, completed_today: completed_today}
  end

  @impl true
  def init(opts) do
    run_process_opts =
      opts
      |> Keyword.get(:run_process_opts, %{})
      |> normalize_run_process_opts()

    state = %{
      run_supervisor: Keyword.get(opts, :run_supervisor, LemonRouter.RunSupervisor),
      run_process_module: Keyword.get(opts, :run_process_module, RunProcess),
      run_process_opts: run_process_opts
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, %RunRequest{} = params}, _from, state) do
    result = do_submit(params, state)
    {:reply, result, state}
  end

  def handle_call(
        {:start_run_process, submission, coordinator_pid, conversation_key},
        _from,
        state
      ) do
    result = do_start_run_process(submission, coordinator_pid, conversation_key, state)
    {:reply, result, state}
  end

  def handle_call({:submit, _invalid}, _from, state) do
    {:reply, {:error, :invalid_run_request}, state}
  end

  defp do_submit(%RunRequest{} = params, orchestrator_state) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    queue_mode = params.queue_mode || :collect
    engine_id = params.engine_id

    # Generate run_id (honor caller-provided run_id for cron jobs to avoid race conditions)
    run_id = params.run_id || LemonCore.Id.run_id()
    request = %RunRequest{params | run_id: run_id}

    # Emit introspection event for orchestration start
    Introspection.record(
      :orchestration_started,
      %{
        origin: origin,
        agent_id: agent_id,
        queue_mode: queue_mode,
        engine_id: engine_id
      },
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      engine: "lemon",
      provenance: :direct
    )

    case SubmissionBuilder.build(request, orchestrator_state) do
      {:ok, %Submission{} = submission} ->
        LemonCore.EventBridge.subscribe_run(run_id)

        case SessionCoordinator.submit(submission.conversation_key, submission) do
          :ok ->
            execution_request = submission.execution_request
            meta = submission.meta || %{}

            Introspection.record(
              :orchestration_resolved,
              %{
                engine_id: execution_request.engine_id,
                model: meta[:model],
                conversation_key: inspect(execution_request.conversation_key)
              },
              run_id: run_id,
              session_key: submission.session_key,
              agent_id: meta[:agent_id] || agent_id,
              engine: "lemon",
              provenance: :direct
            )

            LemonCore.Telemetry.run_submit(
              submission.session_key,
              origin,
              execution_request.engine_id || "default"
            )

            {:ok, run_id}

          {:error, reason} ->
            LemonCore.EventBridge.unsubscribe_run(run_id)

            Introspection.record(
              :orchestration_failed,
              %{
                reason: safe_error_label(reason)
              },
              run_id: run_id,
              session_key: session_key,
              agent_id: agent_id,
              engine: "lemon",
              provenance: :direct
            )

            Logger.error("Failed to submit run to session coordinator: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Introspection.record(
          :orchestration_failed,
          %{
            reason: safe_error_label(reason)
          },
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id,
          engine: "lemon",
          provenance: :direct
        )

        {:error, reason}
    end
  end

  defp do_start_run_process(submission, coordinator_pid, conversation_key, state)
       when is_map(submission) do
    submission =
      submission
      |> enrich_submission_defaults(state)
      |> Submission.new!()

    RunStarter.start(submission, coordinator_pid, conversation_key)
  end

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}

  defp enrich_submission_defaults(%Submission{} = submission, state) do
    submission
    |> Map.from_struct()
    |> enrich_submission_defaults(state)
  end

  defp enrich_submission_defaults(attrs, state) when is_map(attrs) do
    attrs
    |> put_default(:run_supervisor, state.run_supervisor)
    |> put_default(:run_process_module, state.run_process_module)
    |> put_default(:run_process_opts, state.run_process_opts)
  end

  defp put_default(attrs, key, value) do
    if is_nil(MapHelpers.get_key(attrs, key)) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  # Produce a safe, bounded label for introspection error payloads.
  defp safe_error_label(nil), do: nil
  defp safe_error_label(err) when is_atom(err), do: Atom.to_string(err)
  defp safe_error_label(err) when is_binary(err), do: String.slice(err, 0, 80)

  defp safe_error_label(%{__exception__: true} = err),
    do: err.__struct__ |> Module.split() |> Enum.join(".") |> String.slice(0, 80)

  defp safe_error_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_error_label(_), do: "unknown_error"
end
