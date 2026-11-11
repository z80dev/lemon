defmodule LemonCore.Update.Daemon do
  @moduledoc """
  Coordinated restart of exactly the Lemon processes observed before an update
  transaction.

  The controller's ownership and process identity are verified by the packaged
  launcher's private `__update-daemon` hook. A stopped snapshot never starts a
  daemon. Restart runs the selected version's absolute launcher, with inherited
  release-selection variables removed, only after the pointer and durable
  receipt are committed.

  When `LemonCore.Service` manages units on this machine, the snapshot also
  records the *running* Lemon-owned worker units and the backend unit. An
  inventory the service layer refuses (no reachable manager, no GUI session)
  fails the snapshot rather than passing for "no units". The restart then
  follows the order row 4 (InvWorkerState) requires:

    1. stop the running worker units;
    2. restart the controller — only once every one of them is proven stopped;
    3. start those worker units again;
    4. restart the backend unit when it was running.

  Worker shutdown gates controller restart; controller readiness gates worker
  and backend starts. Workers that refuse to stop leave the controller and
  backend untouched, and a controller that fails to come back leaves workers
  down rather than reconnecting to a port nobody serves. Units installed but not running at snapshot
  time are never started: a stopped unit stays stopped, exactly like a stopped
  controller.
  """

  alias LemonCore.Update.ManagedInstall

  @type unit :: map()
  @type snapshot :: %{
          controller: :stopped | String.t(),
          workers: [unit()],
          backend: unit() | nil,
          backend_installed?: boolean()
        }

  @spec snapshot(String.t(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def snapshot(version, opts) do
    with {:ok, controller} <- snapshot_controller(version, opts),
         {:ok, units} <- running_units(opts) do
      workers = Enum.filter(units, &(role(&1) == "worker"))
      backend = Enum.find(units, &(role(&1) == "backend"))

      with {:ok, installed?} <- backend_unit_installed?(backend, opts) do
        {:ok,
         %{
           controller: controller,
           workers: workers,
           backend: backend,
           backend_installed?: installed?
         }}
      end
    end
  end

  @spec restart(map(), snapshot(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:daemon_restart_failed, map()}}
  def restart(result, %{} = snapshot, previous, target, opts) do
    workers = Map.fetch!(snapshot, :workers)
    backend = Map.fetch!(snapshot, :backend)
    controller = Map.fetch!(snapshot, :controller)

    # Nothing downstream may run until every worker observed running is proven
    # stopped: restarting the controller under a live worker is exactly the
    # race row 4 asked this ordering to remove.
    stopped = if workers == [], do: :ok, else: stop_units(workers, opts)
    controller_outcome = restart_controller(controller, stopped, previous, target, opts)
    started = start_workers(workers, stopped, controller_outcome, opts)
    backend_outcome = restart_backend(backend, controller_outcome, opts)

    outcome =
      Map.merge(result, %{
        restart: controller_status(controller, controller_outcome),
        workers: worker_status(workers, stopped, started),
        backend: backend_status(backend, backend_outcome, snapshot)
      })

    failed? = "failed" in [outcome.restart, outcome.workers, outcome.backend]
    outcome = Map.put(outcome, :restart_required, failed?)

    if failed?, do: {:error, {:daemon_restart_failed, outcome}}, else: {:ok, outcome}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Controller
  # ──────────────────────────────────────────────────────────────────────────

  defp snapshot_controller(version, opts) do
    case command(ManagedInstall.launcher(version, opts), ["__update-daemon", "snapshot"], opts) do
      {:ok, "stopped"} ->
        {:ok, :stopped}

      {:ok, token} ->
        if Regex.match?(~r/\A[a-f0-9]{64}\z/, token),
          do: {:ok, token},
          else: {:error, :daemon_ownership_unverified}

      :error ->
        {:error, :daemon_ownership_unverified}
    end
  end

  defp restart_controller(_controller, {:error, _reason}, _previous, _target, _opts),
    do: {:error, :workers_not_stopped}

  defp restart_controller(:stopped, :ok, _previous, _target, _opts), do: :ok

  defp restart_controller(token, :ok, previous, target, opts) when is_binary(token) do
    launcher = ManagedInstall.launcher(target, opts)
    previous_root = previous |> ManagedInstall.launcher(opts) |> Path.dirname() |> Path.dirname()

    case command(launcher, ["__update-daemon", "restart", token, previous_root], opts) do
      {:ok, _output} -> :ok
      :error -> {:error, :controller_restart_failed}
    end
  end

  defp controller_status(:stopped, _outcome), do: "not_running"
  defp controller_status(_token, :ok), do: "restarted"
  defp controller_status(_token, _outcome), do: "failed"

  # ──────────────────────────────────────────────────────────────────────────
  # Workers and backend
  # ──────────────────────────────────────────────────────────────────────────

  # Workers are only brought back once the controller is healthy again; a
  # failed controller restart must not leave half the fleet reconnecting to a
  # port nobody serves.
  defp start_workers([], _stopped, _controller_outcome, _opts), do: :ok
  defp start_workers(_workers, {:error, _} = stopped, _controller_outcome, _opts), do: stopped
  defp start_workers(_workers, :ok, {:error, _reason}, _opts), do: {:error, :controller_unhealthy}
  defp start_workers(workers, :ok, :ok, opts), do: start_units(workers, opts)

  defp restart_backend(nil, _controller_outcome, _opts), do: :ok
  defp restart_backend(_backend, {:error, _reason}, _opts), do: {:error, :controller_unhealthy}
  defp restart_backend(backend, :ok, opts), do: restart_units([backend], opts)

  defp worker_status([], _stopped, _started), do: "not_running"
  defp worker_status(_workers, :ok, :ok), do: "restarted"
  defp worker_status(_workers, _stopped, _started), do: "failed"

  defp backend_status(nil, _outcome, snapshot) do
    if Map.get(snapshot, :backend_installed?, false), do: "not_running", else: "not_installed"
  end

  defp backend_status(_backend, :ok, _snapshot), do: "restarted"
  defp backend_status(_backend, _outcome, _snapshot), do: "failed"

  # ──────────────────────────────────────────────────────────────────────────
  # LemonCore.Service seam
  #
  # Every call carries `:home` derived from the same paths the update itself
  # uses, so an update scoped away from the real `~/.lemon` (tests, a sandboxed
  # install) can never reach the units of the logged-in user. Nothing here
  # swallows a failure: an unreadable inventory or a refused unit operation is
  # reported, never reported as "no units" or "done".
  # ──────────────────────────────────────────────────────────────────────────

  # `running_units/1` answers with a list, or with a stable error when the
  # inventory cannot be read — Lemon-owned units exist but the manager is
  # unreachable, for example. That error must reach the caller: restarting the
  # controller while uninspectable workers may still be running is exactly what
  # the ordering exists to prevent.
  defp running_units(opts) do
    case Keyword.fetch(opts, :service_running_units) do
      {:ok, value} -> normalize_units(value)
      :error -> normalize_units(LemonCore.Service.running_units(service_opts(opts)))
    end
  end

  defp normalize_units(units) when is_list(units), do: {:ok, units}
  defp normalize_units({:ok, units}) when is_list(units), do: {:ok, units}
  defp normalize_units({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_units(_other), do: {:error, :unit_inventory_unavailable}

  defp stop_units(units, opts), do: units_call(:stop_units_fun, :stop_units, units, opts)
  defp start_units(units, opts), do: units_call(:start_units_fun, :start_units, units, opts)

  defp restart_units(units, opts),
    do: units_call(:restart_units_fun, :restart_units, units, opts)

  defp units_call(opt_key, function, units, opts) do
    outcome =
      case Keyword.fetch(opts, opt_key) do
        {:ok, fun} when is_function(fun, 2) -> fun.(units, opts)
        _ -> apply(LemonCore.Service, function, [units, service_opts(opts)])
      end

    case outcome do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :service_unit_operation_failed}
    end
  end

  defp backend_unit_installed?(backend, _opts) when not is_nil(backend), do: {:ok, true}

  defp backend_unit_installed?(_backend, opts) do
    case Keyword.fetch(opts, :backend_unit_installed) do
      {:ok, installed?} when is_boolean(installed?) ->
        {:ok, installed?}

      {:ok, _other} ->
        {:error, :invalid_unit_snapshot}

      :error ->
        case LemonCore.Service.status(["backend"], service_opts(opts)) do
          {:ok, %{units: units}} when is_list(units) ->
            {:ok, Enum.any?(units, &(Map.get(&1, :installed) == true))}

          {:error, reason} when is_atom(reason) ->
            {:error, reason}

          _other ->
            {:error, :unit_inventory_unavailable}
        end
    end
  end

  defp service_opts(opts) do
    Keyword.put_new_lazy(opts, :home, fn ->
      LemonCore.Paths.home_dir(Keyword.get(opts, :paths_opts, []))
    end)
  end

  defp role(unit) do
    case Map.get(unit, :role) || Map.get(unit, "role") do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  # Every OS call in the lifecycle path goes through the same injectable
  # runner contract the service layer uses: fn executable, argv, system_opts.
  defp command(launcher, args, opts) do
    runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    system_opts = [
      env: Keyword.get_lazy(opts, :release_command_env, &ManagedInstall.command_env/0),
      stderr_to_stdout: true
    ]

    task =
      Task.async(fn ->
        try do
          runner.(launcher, args, system_opts)
        rescue
          _ -> {"", 1}
        end
      end)

    case Task.yield(task, 180_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} when is_binary(output) -> {:ok, String.trim(output)}
      _ -> :error
    end
  end
end
