defmodule LemonCore.Service.Manual do
  @moduledoc false
  @behaviour LemonCore.Service.Manager
  alias LemonCore.Service.{Command, Identity, Readiness, Role, Unit}

  def available?(_), do: true
  def persistence(_), do: {"none", nil}
  def record_path(spec, opts), do: Path.join(Role.run_dir(opts), spec.label <> ".pid")

  def install(spec, opts) do
    with :ok <- Unit.write(spec, "none"), do: start(spec, opts)
  end

  def status(%{role: "controller"} = spec, opts) do
    pid = Readiness.controller_pid(spec.port, opts)

    verified =
      case Command.run(Role.launcher(opts), ["__update-daemon", "snapshot"], opts,
             env: [{"LEMON_CONTROL_PLANE_PORT", to_string(spec.port)}]
           ) do
        {token, 0} -> Regex.match?(~r/\A[a-f0-9]{64}\z/, String.trim(token))
        _ -> false
      end

    %{loaded: File.exists?(spec.path), pid: if(verified, do: pid, else: nil), failed: false}
  end

  def status(spec, opts) do
    pid =
      case recorded_identity(spec, opts) do
        {:ok, identity} -> identity.pid
        _ -> nil
      end

    %{loaded: File.exists?(spec.path), pid: pid, failed: false}
  end

  def start(%{role: "controller"} = spec, opts),
    do:
      Command.ok(Role.launcher(opts), ["daemon"], opts,
        env: [{"LEMON_CONTROL_PLANE_PORT", to_string(spec.port)}]
      )

  def start(spec, opts) do
    File.mkdir_p!(Path.dirname(spec.log))
    # Only positional arguments cross the shell boundary; no command interpolation.
    script =
      "log=$1; shift; if command -v setsid >/dev/null 2>&1; then setsid nohup \"$@\" </dev/null >>\"$log\" 2>&1 & else nohup \"$@\" </dev/null >>\"$log\" 2>&1 & fi; echo $!"

    env_args = Enum.map(spec.env, fn {key, value} -> key <> "=" <> value end)

    case Command.run(
           "/bin/sh",
           ["-c", script, "lemon-service", spec.log, "env", "-i"] ++ env_args ++ spec.argv,
           opts, cd: spec.home) do
      {output, 0} ->
        with {pid, ""} <- Integer.parse(String.trim(output)),
             {:ok, identity} <- Identity.capture(pid, opts) do
          record = %{pid: pid, startedAt: identity.started_at, argvHash: argv_hash(spec)}
          Unit.atomic_write(record_path(spec, opts), Jason.encode!(record), 0o600)
        else
          _ -> {:error, :manual_start_failed}
        end

      _ ->
        {:error, :manual_start_failed}
    end
  end

  def restart(spec, opts) do
    with :ok <- stop(spec, opts), do: start(spec, opts)
  end

  def stop(%{role: "controller"} = spec, opts) do
    env = [{"LEMON_CONTROL_PLANE_PORT", to_string(spec.port)}]

    case Command.run(Role.launcher(opts), ["__update-daemon", "snapshot"], opts, env: env) do
      {output, 0} ->
        token = String.trim(output)

        cond do
          token == "stopped" ->
            :ok

          Regex.match?(~r/\A[a-f0-9]{64}\z/, token) ->
            Command.ok(Role.launcher(opts), ["__update-daemon", "stop", token], opts, env: env)

          true ->
            {:error, :daemon_ownership_unverified}
        end

      _ ->
        {:error, :daemon_ownership_unverified}
    end
  end

  def stop(spec, opts) do
    case recorded_identity(spec, opts) do
      {:ok, identity} ->
        with :ok <- Identity.terminate(identity, opts) do
          File.rm(record_path(spec, opts))
          :ok
        end

      {:error, :not_found} ->
        :ok

      {:error, :stale_record} ->
        :ok

      _ ->
        {:error, :process_identity_unverified}
    end
  end

  def unload(spec, opts), do: stop(spec, opts)

  def uninstall(spec, opts) do
    with :ok <- stop(spec, opts) do
      File.rm(record_path(spec, opts))

      case File.rm(spec.path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        _ -> {:error, :unit_remove_failed}
      end
    end
  end

  defp recorded_identity(spec, opts) do
    with {:ok, %{"pid" => pid, "startedAt" => started, "argvHash" => hash}}
         when is_integer(pid) and pid > 1 and is_binary(started) and is_binary(hash) <-
           Identity.read_json(record_path(spec, opts)),
         true <- hash == argv_hash(spec) do
      case Identity.capture(pid, opts) do
        {:ok, identity} ->
          if identity.started_at == started, do: {:ok, identity}, else: {:error, :stale_record}

        _ ->
          if Identity.gone?(%{pid: pid, started_at: started}, opts),
            do: {:error, :stale_record},
            else: {:error, :process_identity_unverified}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :process_identity_unverified}
    end
  end

  defp argv_hash(spec),
    do: :crypto.hash(:sha256, Jason.encode!(spec.argv)) |> Base.encode16(case: :lower)
end
