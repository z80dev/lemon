defmodule LemonCore.Service.Takeover do
  @moduledoc "Adopts only proven same-user processes; never signals an ambiguous port owner."
  alias LemonCore.Service.{Command, Identity, Readiness, Role}

  def prepare(%{role: "controller"} = spec, manager, opts) do
    snapshot =
      case Keyword.fetch(opts, :controller_snapshot) do
        {:ok, value} -> {:ok, value}
        :error -> controller_snapshot(spec, manager, opts)
      end

    case snapshot do
      {:ok, state} when state in [:supervised, :stopped] ->
        {:ok, false}

      {:ok, token} ->
        IO.puts(:stderr, "Adopting the verified controller; it will briefly be unavailable.")

        case Command.ok(Role.launcher(opts), ["__update-daemon", "stop", token], opts,
               env: [{"LEMON_CONTROL_PLANE_PORT", to_string(spec.port)}]
             ) do
          :ok -> {:ok, true}
          _ -> {:error, :daemon_ownership_unverified}
        end

      error ->
        error
    end
  end

  def prepare(%{role: "backend"} = spec, manager, opts) do
    case Readiness.probe(spec, manager, opts) do
      {"ready", _} -> {:ok, false}
      _ -> backend(spec, opts)
    end
  end

  def prepare(%{role: "worker", name: name}, manager, opts) do
    case Identity.legacy_workers(name, opts) do
      {:error, _} = error ->
        error

      identities ->
        identities
        |> Enum.reject(&(&1.pid == manager.pid))
        |> Enum.reduce_while({:ok, false}, fn identity, _ ->
          case Identity.terminate(identity, opts) do
            :ok -> {:cont, {:ok, true}}
            error -> {:halt, error}
          end
        end)
    end
  end

  def prepare(%{role: "tunnel"}, _, _), do: {:ok, false}

  def controller_snapshot(spec, manager, opts) do
    if manager.pid && manager.pid == Readiness.controller_pid(spec.port, opts) do
      {:ok, :supervised}
    else
      case Command.run(Role.launcher(opts), ["__update-daemon", "snapshot"], opts,
             env: [{"LEMON_CONTROL_PLANE_PORT", to_string(spec.port)}]
           ) do
        {output, 0} ->
          value = String.trim(output)

          cond do
            value == "stopped" -> {:ok, :stopped}
            Regex.match?(~r/\A[a-f0-9]{64}\z/, value) -> {:ok, value}
            true -> {:error, :daemon_ownership_unverified}
          end

        {output, _} ->
          {:error, snapshot_error(output)}
      end
    end
  end

  defp backend(spec, opts) do
    case Identity.listeners(spec.port, opts) do
      [] ->
        {:ok, false}

      [pid] ->
        with {:ok, identity} <- Identity.capture(pid, opts),
             {:ok, %{"product" => "lemon_bot", "instanceId" => instance}} when is_binary(instance) <-
               Readiness.http_json("http://127.0.0.1:#{spec.port}/v1/setup", opts),
             :ok <- backend_identity(spec, identity, instance, opts),
             :ok <- Identity.terminate(identity, opts) do
          {:ok, true}
        else
          {:error, :stop_timeout} -> {:error, :stop_timeout}
          _ -> {:error, :port_in_use_foreign}
        end

      _ ->
        {:error, :port_in_use_foreign}
    end
  end

  defp backend_identity(spec, identity, instance, opts) do
    case Identity.read_json(Readiness.backend_record(spec, opts)) do
      {:ok, %{"pid" => pid, "startedAt" => started, "instanceId" => ^instance}} ->
        if pid == identity.pid and Identity.normalize_time(started) == identity.started_at,
          do: :ok,
          else: {:error, :process_identity_unverified}

      {:error, :not_found} ->
        if Identity.backend_program?(identity, List.first(spec.argv), opts),
          do: :ok,
          else: {:error, :process_identity_unverified}

      _ ->
        {:error, :process_identity_unverified}
    end
  end

  defp snapshot_error(output) do
    Enum.find(
      [:restore_in_progress, :port_in_use_foreign, :unhealthy_recorded_runtime],
      :daemon_ownership_unverified,
      fn code -> String.contains?(output, Atom.to_string(code)) end
    )
  end
end
