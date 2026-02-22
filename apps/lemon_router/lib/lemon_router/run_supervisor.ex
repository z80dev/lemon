defmodule LemonRouter.RunSupervisor do
  @moduledoc """
  DynamicSupervisor that manages `LemonRouter.RunProcess` processes.

  Each run is started as a temporary child so it is not restarted on failure.
  This supervisor provides logging for run process lifecycle events.
  """

  use DynamicSupervisor

  require Logger

  @default_max_children 500

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max_children = Keyword.get(opts, :max_children, run_process_limit())

    Logger.info(
      "RunSupervisor starting name=#{inspect(name)} max_children=#{inspect(max_children)}"
    )

    DynamicSupervisor.start_link(__MODULE__, %{max_children: max_children}, name: name)
  end

  @impl true
  def init(%{max_children: max_children}) do
    Logger.debug("RunSupervisor initializing with max_children=#{inspect(max_children)}")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_children
    )
  end

  @doc """
  Starts a new `LemonRouter.RunProcess` process as a temporary child of this supervisor.
  Logs the start attempt and result.
  """
  @spec start_run(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def start_run(args) when is_list(args) or is_map(args) do
    run_id = args[:run_id] || args["run_id"]
    session_key = args[:session_key] || args["session_key"]

    Logger.info(
      "RunSupervisor starting run process run_id=#{inspect(run_id)} " <>
        "session_key=#{inspect(session_key)}"
    )

    spec =
      Supervisor.child_spec({LemonRouter.RunProcess, args},
        restart: :temporary,
        shutdown: 5_000
      )

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info(
          "RunSupervisor run process started successfully run_id=#{inspect(run_id)} pid=#{inspect(pid)}"
        )

        {:ok, pid}

      {:ok, pid, info} ->
        Logger.info(
          "RunSupervisor run process started successfully run_id=#{inspect(run_id)} pid=#{inspect(pid)} info=#{inspect(info)}"
        )

        {:ok, pid, info}

      {:error, {:already_started, pid}} ->
        Logger.warning(
          "RunSupervisor run process already started run_id=#{inspect(run_id)} pid=#{inspect(pid)}"
        )

        {:error, {:already_started, pid}}

      {:error, :max_children} ->
        Logger.error(
          "RunSupervisor max children reached, cannot start run_id=#{inspect(run_id)} " <>
            "session_key=#{inspect(session_key)}"
        )

        {:error, :max_children}

      {:error, {:noproc, _}} = error ->
        Logger.error(
          "RunSupervisor failed to start run_id=#{inspect(run_id)} - router not ready"
        )

        error

      {:error, :noproc} = error ->
        Logger.error(
          "RunSupervisor failed to start run_id=#{inspect(run_id)} - router not ready"
        )

        error

      {:error, reason} = error ->
        Logger.error(
          "RunSupervisor failed to start run_id=#{inspect(run_id)} reason=#{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Terminates a child process by PID. Logs the termination request.
  """
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) when is_pid(pid) do
    Logger.info("RunSupervisor terminating child pid=#{inspect(pid)}")

    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok ->
        Logger.debug("RunSupervisor child terminated successfully pid=#{inspect(pid)}")
        :ok

      {:error, :not_found} = error ->
        Logger.warning("RunSupervisor child not found for termination pid=#{inspect(pid)}")
        error
    end
  end

  @doc """
  Returns information about all children. Logs the count.
  """
  @spec which_children() :: [{:undefined, pid() | :restarting, :worker, [module()]}]
  def which_children do
    children = DynamicSupervisor.which_children(__MODULE__)
    count = length(children)

    Logger.debug("RunSupervisor which_children count=#{count}")

    children
  end

  @doc """
  Returns count information about the supervisor. Logs the details.
  """
  @spec count_children() :: %{
          specs: non_neg_integer(),
          active: non_neg_integer(),
          supervisors: non_neg_integer(),
          workers: non_neg_integer()
        }
  def count_children do
    counts = DynamicSupervisor.count_children(__MODULE__)

    Logger.debug(
      "RunSupervisor count_children specs=#{counts.specs} active=#{counts.active} " <>
        "workers=#{counts.workers}"
    )

    counts
  end

  @doc """
  Handles child termination events (called via telemetry or monitoring).
  This is a hook for logging child termination events.
  """
  @spec log_child_terminated(pid(), term(), term()) :: :ok
  def log_child_terminated(pid, reason, run_id) do
    log_level = if reason == :normal, do: :debug, else: :info

    Logger.log(
      log_level,
      "RunSupervisor child terminated pid=#{inspect(pid)} run_id=#{inspect(run_id)} reason=#{inspect(reason)}"
    )

    :ok
  end

  # Private function to get run process limit from application config
  defp run_process_limit do
    case Application.get_env(:lemon_router, :run_process_limit, @default_max_children) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      _ ->
        @default_max_children
    end
  end
end
