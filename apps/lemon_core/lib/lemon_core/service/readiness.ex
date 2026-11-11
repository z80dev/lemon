defmodule LemonCore.Service.Readiness do
  @moduledoc "Readiness is application health plus supervisor/process identity, never log scraping."
  alias LemonCore.Service.{Command, Identity, Role}

  @worker_states ~w(starting online reconnecting needs_reauthorization needs_enrollment conflict)
  @worker_reasons ~w(session_expired session_invalid node_not_found credential_rejected credential_missing credential_unreadable controller_mismatch node_name_conflict node_identity_mismatch)

  def probe(%{role: "controller"} = spec, manager, opts) do
    healthy =
      match?({:ok, %{"ok" => true}}, http_json("http://127.0.0.1:#{spec.port}/healthz", opts))

    pid = controller_pid(spec.port, opts)

    cond do
      healthy and is_integer(pid) and pid == manager.pid -> {"ready", nil}
      healthy -> {"unsupervised", nil}
      manager.pid -> {"starting", nil}
      true -> {stopped_state(manager), nil}
    end
  end

  def probe(%{role: "backend"} = spec, manager, opts) do
    response = http_json("http://127.0.0.1:#{spec.port}/v1/setup", opts)
    record = Identity.read_json(backend_record(spec, opts))

    case {response, record} do
      {{:ok, %{"product" => "lemon_bot", "instanceId" => id}},
       {:ok, %{"instanceId" => id, "pid" => pid, "startedAt" => started}}}
      when is_binary(id) ->
        with true <- pid == manager.pid,
             {:ok, identity} <- Identity.capture(pid, opts),
             true <- identity.started_at == Identity.normalize_time(started) do
          {"ready", nil}
        else
          _ -> {"unsupervised", nil}
        end

      {{:ok, %{"product" => "lemon_bot"}}, _} ->
        {"unsupervised", nil}

      _ ->
        {if(manager.pid, do: "starting", else: stopped_state(manager)), nil}
    end
  end

  def probe(%{role: "worker", name: name}, manager, opts) do
    case worker_status(name, opts) do
      {:ok, %{"state" => state, "osPid" => pid} = status} when state in @worker_states ->
        reason = status["reason"]
        detail = if reason in @worker_reasons, do: reason, else: nil

        cond do
          pid == manager.pid and is_integer(pid) -> {state, detail}
          manager.pid -> {"unsupervised", nil}
          true -> {stopped_state(manager), nil}
        end

      {:error, :module_unavailable} ->
        {"unknown", nil}

      _ ->
        {if(manager.pid, do: "starting", else: stopped_state(manager)), nil}
    end
  end

  def probe(%{role: "tunnel", name: name}, manager, opts) do
    case Identity.read_json(Path.join(Role.run_dir(opts), "tunnel-#{name}.json")) do
      {:ok, %{"state" => state} = status} when state in ["online", "reconnecting", "failed"] ->
        detail =
          if status["detail"] in ~w(ssh_auth_failed host_key_changed host_unreachable forward_refused remote_port_in_use),
            do: status["detail"],
            else: nil

        if manager.pid || state == "failed", do: {state, detail}, else: {"stopped", nil}

      _ ->
        {if(manager.pid, do: "starting", else: stopped_state(manager)), nil}
    end
  end

  def http_json(url, opts) do
    case Keyword.get(opts, :http_get) do
      fun when is_function(fun, 1) ->
        fun.(url)

      _ ->
        case Command.run("curl", ["--fail", "--silent", "--max-time", "2", url], opts,
               timeout: 3_000
             ) do
          {body, 0} when byte_size(body) <= 1_048_576 -> Jason.decode(body)
          _ -> {:error, :unavailable}
        end
    end
  end

  def worker_status(name, opts) do
    case Keyword.get(opts, :status_reader) do
      fun when is_function(fun, 1) ->
        fun.(name)

      _ ->
        module = Module.concat([CodingAgent, StatePaths])

        if Code.ensure_loaded?(module) and function_exported?(module, :read_status, 1),
          do: apply(module, :read_status, [name]),
          else: {:error, :module_unavailable}
    end
  end

  def controller_pid(port, opts) do
    path =
      Keyword.get(
        opts,
        :controller_pid_file,
        Path.join([Role.home(opts), ".lemon", "run", "lemon-#{port}.pid"])
      )

    with {:ok, body} <- File.read(path),
         [first | _] <- String.split(body, "\n"),
         {pid, ""} when pid > 1 <- Integer.parse(first) do
      pid
    else
      _ -> nil
    end
  end

  def backend_record(spec, opts) do
    data = Map.get(spec.env, "LEMON_BOT_DATA_DIR", Path.join(Role.home(opts), ".lemon/lemon_bot"))
    Path.join([data, "run", "lemon-bot-#{spec.port}.json"])
  end

  def ready?(%{state: state}), do: state in ["ready", "online"]
  defp stopped_state(%{failed: true}), do: "failed"
  defp stopped_state(_), do: "stopped"
end
