defmodule LemonEvals.PayloadProfile do
  @moduledoc """
  Opt-in, in-memory provider request/usage profiler for a dedicated eval daemon.

  Install after boot with `install!/2`. The offline Python worker requires
  tiktoken and writes only counts, tool names, and hashes to an owner-only JSONL
  file. Raw request bodies never enter artifacts. Normal runtime execution is
  unchanged unless the operator explicitly installs this development adapter.
  """
  use GenServer

  def install!(path, opts \\ []) do
    python = Keyword.get(opts, :python, System.find_executable("python3"))
    {:ok, pid} = GenServer.start_link(__MODULE__, {Path.expand(path), python}, name: __MODULE__)
    CodingAgent.Executor.configure_stream_options(&attach_callbacks/2)

    if Keyword.get(opts, :paired, false) do
      :ok =
        :telemetry.attach_many(
          {__MODULE__, pid},
          [
            [:coding_agent, :tool_disclosure, :invoke],
            [:coding_agent, :tool_disclosure, :applied],
            [:coding_agent, :tool_disclosure, :search],
            [:coding_agent, :tool_disclosure, :invoke_rejected]
          ],
          &__MODULE__.handle_disclosure_event/4,
          pid
        )
    end

    pid
  end

  @doc "Wait for already queued profiling records to reach the owner-only file."
  def flush!(timeout \\ 10_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @doc false
  def handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :invoke],
        measurements,
        metadata,
        pid
      ) do
    name = Map.get(metadata, :tool_name)
    status = Map.get(metadata, :status)

    if is_binary(name) and status in [:ok, :error] do
      data = %{
        resolved_tool_digest: Base.encode16(:crypto.hash(:sha256, name), case: :lower),
        status: Atom.to_string(status),
        duration_us: Map.get(measurements, :duration_us)
      }

      GenServer.cast(pid, {:record, :disclosure_invoke, data, %{}})
    end
  end

  def handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :applied],
        measurements,
        metadata,
        pid
      ) do
    profile = Map.get(metadata, :profile)

    if profile in [:coding, :legacy] do
      data =
        Map.take(measurements, [
          :estimated_tokens,
          :disclosed_tokens,
          :hidden_count,
          :disclosed_count
        ])
        |> Map.merge(%{
          profile: Atom.to_string(profile),
          active: metadata[:active],
          catalog_digest: metadata[:catalog_digest],
          diagnostic_events_version: metadata[:diagnostic_events_version]
        })

      GenServer.cast(
        pid,
        {:record, :disclosure_applied, data, %{}}
      )
    end
  end

  def handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :search],
        measurements,
        metadata,
        pid
      ) do
    status = metadata[:status]
    count = measurements[:matched_count]

    if status in [:ok, :error] and is_integer(count) and count >= 0 do
      GenServer.cast(
        pid,
        {:record, :disclosure_search, %{status: Atom.to_string(status), matched_count: count},
         %{}}
      )
    end
  end

  def handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :invoke_rejected],
        _measurements,
        metadata,
        pid
      ) do
    reason = metadata[:reason]

    if reason in [:unknown_tool, :invalid_arguments, :invalid_request] do
      GenServer.cast(pid, {:record, :disclosure_rejected, %{reason: Atom.to_string(reason)}, %{}})
    end
  end

  def record(event, run_id, data, metadata) do
    metadata = Map.take(metadata, [:provider, :model, :session_id]) |> Map.put(:run_id, run_id)
    GenServer.cast(__MODULE__, {:record, event, data, metadata})
  end

  @impl true
  def init({path, python}) when is_binary(python) do
    script = Path.join(:code.priv_dir(:lemon_evals), "payload_profile.py")

    port =
      LemonCore.NativeProcess.open({:spawn_executable, python}, [
        :binary,
        :use_stdio,
        :exit_status,
        {:line, 1_048_576},
        {:args, [script, path]}
      ])

    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"event" => "ready"}} -> {:ok, %{port: port, pending: 0, waiters: []}}
          _ -> {:stop, :profiling_worker_unavailable}
        end

      {^port, {:exit_status, _}} ->
        {:stop, :profiling_worker_unavailable}
    after
      30_000 ->
        Port.close(port)
        {:stop, :profiling_worker_timeout}
    end
  end

  @impl true
  def handle_cast({:record, event, data, metadata}, state) do
    true =
      Port.command(
        state.port,
        Jason.encode!(%{event: event, data: data, metadata: metadata}) <> "\n"
      )

    {:noreply, %{state | pending: state.pending + 1}}
  end

  @impl true
  def handle_call(:flush, _from, %{pending: 0} = state), do: {:reply, :ok, state}

  def handle_call(:flush, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "recorded"}} ->
        pending = state.pending - 1

        if pending == 0 do
          Enum.each(state.waiters, &GenServer.reply(&1, :ok))
          {:noreply, %{state | pending: 0, waiters: []}}
        else
          {:noreply, %{state | pending: pending}}
        end

      _ ->
        {:stop, :profiling_worker_failed, state}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:stop, :profiling_worker_failed, state}

  @impl true
  def format_status(status) do
    status |> Map.put(:message, :redacted) |> Map.put(:reason, :redacted) |> Map.put(:log, [])
  end

  defp attach_callbacks(run_id, base) do
    base = base || %LemonAi.Types.StreamOptions{}
    on_payload = Map.get(base, :on_payload) || Map.get(base, "on_payload")
    on_usage = Map.get(base, :on_usage) || Map.get(base, "on_usage")

    Map.merge(Map.drop(base, ["on_payload", "on_usage"]), %{
      on_payload: fn body, metadata ->
        if is_function(on_payload, 2), do: on_payload.(body, metadata)
        record(:payload, run_id, body, metadata)
      end,
      on_usage: fn usage, metadata ->
        if is_function(on_usage, 2), do: on_usage.(usage, metadata)
        record(:usage, run_id, usage, metadata)
      end
    })
  end
end
