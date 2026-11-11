defmodule LemonCore.Service do
  @moduledoc """
  Per-user controller, backend and worker supervision with identity-gated adoption.

  Public lifecycle operations return schema-1 documents, never credentials or unit
  arguments. `running_units/1` is an internal update snapshot, not a CLI projection.
  All OS calls accept an injectable `:command_runner` (executable, argv, options).
  """
  alias LemonCore.Service.{
    Command,
    Launchd,
    Lock,
    Manual,
    Readiness,
    Role,
    Systemd,
    Takeover,
    Unit
  }

  @order %{"controller" => 0, "backend" => 1, "worker" => 2, "tunnel" => 3}

  def install(roles, opts \\ []), do: perform(:install, roles, opts)
  def status(roles \\ [], opts \\ []), do: perform(:status, roles, opts)
  def repair(roles \\ [], opts \\ []), do: perform(:repair, roles, opts)
  def uninstall(roles, opts \\ []), do: perform(:uninstall, roles, opts)

  def running_units(opts \\ []) do
    {selected, _, blocked} = manager(opts)

    with :ok <- inventory_available(selected, blocked, opts) do
      running_inventory(selected, opts)
    end
  catch
    :service_inventory_unavailable -> {:error, :service_state_unavailable}
  end

  defp running_inventory(selected, opts) do
    inventory(selected, opts)
    |> Enum.flat_map(fn {role, unit_opts} ->
      local_opts = Keyword.merge(opts, unit_opts)
      manager = Keyword.get(unit_opts, :service_manager, selected)
      module = manager_module(manager)

      case resolve(role, manager, local_opts, :status) do
        {:ok, spec, {:ok, parsed}} ->
          if Unit.owned?(parsed, spec, opts) do
            item = report(spec, module, local_opts)

            if item.pid,
              do: [
                Map.merge(item, %{
                  spec: spec,
                  manager: manager,
                  fingerprint: fingerprint(parsed.body)
                })
              ],
              else: []
          else
            []
          end

        _ ->
          throw(:service_inventory_unavailable)
      end
    end)
  end

  defp inventory_available(selected, blocked, opts) do
    native =
      if Keyword.get(opts, :os, :os.type()) in [:darwin, {:unix, :darwin}],
        do: "launchd",
        else: "systemd"

    cond do
      opts[:manual] ->
        :ok

      blocked && discover(native, opts) != [] ->
        {:error, blocked}

      selected == "none" and discover(native, opts) != [] ->
        {:error, :service_manager_unavailable}

      true ->
        :ok
    end
  end

  def stop_units(units, opts \\ []), do: manage_units(units, :stop, opts)
  def start_units(units, opts \\ []), do: manage_units(units, :start, opts)
  def restart_units(units, opts \\ []), do: manage_units(units, :restart, opts)

  def manager(opts) do
    cond do
      opts[:manual] ->
        {"none", Manual, nil}

      Keyword.get(opts, :os, :os.type()) in [:darwin, {:unix, :darwin}] ->
        {"launchd", Launchd, if(Launchd.available?(opts), do: nil, else: :gui_session_required)}

      Keyword.get(opts, :os, :os.type()) in [:linux, {:unix, :linux}] and Systemd.available?(opts) ->
        {"systemd", Systemd, nil}

      true ->
        {"none", Manual, nil}
    end
  end

  defp perform(operation, roles, opts) do
    {manager, module, blocked} = manager(opts)

    with :ok <- validate_roles(operation, roles),
         :ok <- validate_name(opts),
         :ok <- if(manager == "none", do: inventory_available(manager, blocked, opts), else: :ok),
         :ok <- validate_invite(roles, opts) do
      if operation in [:install, :repair] and opts[:enable_linger] == true and
           manager == "systemd",
         do: Systemd.enable_linger(opts)

      if operation in [:install, :repair] and manager == "none",
        do:
          IO.puts(
            :stderr,
            "No service manager: Lemon stops at reboot/logout; run `lemon service repair` after restarting"
          )

      targets = operation_targets(operation, roles, manager, opts)

      results =
        Enum.map(targets, fn {role, unit_opts} ->
          local_opts = Keyword.merge(opts, unit_opts)
          local_manager = Keyword.get(unit_opts, :service_manager, manager)
          module = manager_module(local_manager)
          blocked = if local_manager == "none", do: nil, else: blocked
          manager = local_manager

          case resolve(role, manager, local_opts, operation) do
            {:ok, spec, existing} ->
              cond do
                existing != {:error, :not_found} and
                    not owned_existing?(existing, spec, local_opts) ->
                  spec
                  |> base()
                  |> Map.merge(%{installed: true, state: "foreign", detail: "unit_foreign"})

                blocked ->
                  spec
                  |> base()
                  |> Map.merge(%{
                    installed: match?({:ok, _}, existing),
                    state: "blocked",
                    detail: to_string(blocked)
                  })

                operation == :status ->
                  report(spec, module, local_opts)

                true ->
                  case Lock.with_lock(spec.label, local_opts, fn ->
                         mutate(operation, spec, manager, module, local_opts)
                       end) do
                    {:ok, item} ->
                      item

                    {:error, reason} ->
                      spec
                      |> base()
                      |> Map.merge(%{
                        installed: File.exists?(spec.path),
                        state: "blocked"
                      })
                      |> Map.merge(error_fields(reason))
                  end
              end

            {:error, reason} ->
              shell_spec(role, manager, local_opts)
              |> base()
              |> Map.merge(%{state: "blocked", detail: to_string(reason)})
          end
        end)

      manual? =
        Enum.any?(targets, fn {_, target_opts} -> target_opts[:service_manager] == "none" end)

      {persistence, linger} = if manual?, do: {"none", nil}, else: module.persistence(opts)

      {:ok,
       %{
         schema: 1,
         manager: if(manual?, do: "none", else: manager),
         persistence: persistence,
         linger: linger,
         units: results
       }}
    end
  catch
    :service_inventory_unavailable -> {:error, :service_state_unavailable}
  end

  defp validate_roles(operation, []) when operation in [:install, :uninstall],
    do: {:error, :role_required}

  defp validate_roles(_, roles) do
    if Enum.all?(roles, &(&1 in Role.roles())), do: :ok, else: {:error, :invalid_role}
  end

  defp validate_name(opts) do
    if is_nil(opts[:name]) or Role.valid_name?(opts[:name]),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp validate_invite(roles, opts) do
    case opts[:invite_code] do
      nil ->
        :ok

      code when is_binary(code) ->
        if roles == ["worker"] and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, code),
          do: :ok,
          else: {:error, :invalid_invite_code}

      _ ->
        {:error, :invalid_invite_code}
    end
  end

  defp targets([], manager, opts), do: discover(manager, opts)

  defp targets(roles, manager, opts) do
    Enum.flat_map(Enum.uniq(roles), fn role ->
      if role in ["worker", "tunnel"] and is_nil(opts[:name]) do
        found = Enum.filter(discover(manager, opts), fn {candidate, _} -> candidate == role end)
        if found == [], do: [{role, []}], else: found
      else
        [{role, []}]
      end
    end)
    |> Enum.sort_by(fn {role, _} -> Map.fetch!(@order, role) end)
  end

  defp inventory(manager, opts) do
    manual =
      if manager == "none",
        do: [],
        else:
          Enum.map(discover("none", opts), fn {role, options} ->
            {role, Keyword.put(options, :service_manager, "none")}
          end)

    discover(manager, opts) ++ manual
  end

  defp operation_targets(:install, roles, manager, opts), do: targets(roles, manager, opts)
  defp operation_targets(_, [], manager, opts), do: inventory(manager, opts)

  defp operation_targets(_, roles, manager, opts) do
    manual =
      if manager == "none",
        do: [],
        else:
          inventory(manager, opts)
          |> Enum.filter(fn {role, options} ->
            role in roles and options[:service_manager] == "none"
          end)

    normal =
      targets(roles, manager, opts)
      |> Enum.reject(fn {role, options} ->
        spec = shell_spec(role, manager, Keyword.merge(opts, options))

        not File.exists?(spec.path) and
          Enum.any?(manual, fn {candidate, candidate_opts} ->
            other = shell_spec(candidate, "none", Keyword.merge(opts, candidate_opts))
            {spec.role, spec.name, spec.port} == {other.role, other.name, other.port}
          end)
      end)

    normal ++ manual
  end

  defp manager_module("launchd"), do: Launchd
  defp manager_module("systemd"), do: Systemd
  defp manager_module("none"), do: Manual

  def discover(manager, opts) do
    directory =
      case manager do
        "launchd" -> Path.join(Role.home(opts), "Library/LaunchAgents")
        "systemd" -> Role.systemd_unit_dir(opts)
        "none" -> Role.run_dir(opts)
      end

    case File.ls(directory) do
      {:ok, files} ->
        files
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          case Role.identity(file) do
            {role, options} ->
              expected =
                shell_spec(role, manager, Keyword.merge(opts, options)).path |> Path.basename()

              cond do
                expected != file -> []
                opts[:name] && role in ["worker", "tunnel"] && options[:name] != opts[:name] -> []
                true -> [{role, options}]
              end

            _ ->
              []
          end
        end)
        |> Enum.sort_by(fn {role, _} -> @order[role] end)

      {:error, :enoent} ->
        []

      {:error, _} ->
        throw(:service_inventory_unavailable)
    end
  end

  defp resolve(role, manager, opts, operation) do
    shell = shell_spec(role, manager, opts)
    existing = Unit.read(shell.path, manager)

    case existing do
      {:ok, parsed} ->
        inherited = Role.options_from_argv(parsed.argv)
        merged = Keyword.merge(inherited, opts)
        env = Map.merge(Keyword.get(opts, :env, System.get_env()), parsed.env)
        merged = Keyword.put(merged, :env, env)

        merged =
          case parsed.env["PATH"] do
            path when is_binary(path) -> Keyword.put(merged, :login_path, path)
            _ -> merged
          end

        if operation in [:status, :uninstall] do
          {:ok, Map.merge(shell, %{argv: parsed.argv, env: parsed.env, options: merged}),
           existing}
        else
          case Role.build(role, manager, merged) do
            {:ok, spec} -> {:ok, spec, existing}
            error -> error
          end
        end

      {:error, :not_found} when operation in [:status, :uninstall, :repair] ->
        {:ok, shell, existing}

      {:error, :not_found} ->
        case Role.build(role, manager, opts) do
          {:ok, spec} -> {:ok, spec, existing}
          error -> error
        end

      _ ->
        {:ok, shell, existing}
    end
  end

  defp shell_spec(role, manager, opts) do
    name = if role in ["worker", "tunnel"], do: opts[:name], else: nil
    port = if role in ["controller", "backend"], do: Role.port(role, opts), else: nil
    label = Role.label(role, manager, name, port)
    log_role = if role == "worker", do: "node", else: role

    %{
      role: role,
      name: name,
      label: label,
      port: port,
      home: Role.home(opts),
      path: Role.unit_path(label, manager, opts),
      argv: [],
      env: %{},
      options: opts,
      log:
        Path.join([
          Role.home(opts),
          ".lemon",
          "logs",
          log_role <> if(name, do: "-" <> name, else: "") <> ".log"
        ])
    }
  end

  defp owned_existing?({:ok, parsed}, spec, opts), do: Unit.owned?(parsed, spec, opts)
  defp owned_existing?(_, _, _), do: false

  defp mutate(:uninstall, spec, manager, module, opts) do
    case Unit.read(spec.path, manager) do
      {:error, :not_found} ->
        if opts[:expected_fingerprint],
          do: {:error, :unit_changed},
          else: {:ok, Map.put(base(spec), :action, "removed")}

      {:ok, parsed} ->
        cond do
          opts[:expected_fingerprint] && opts[:expected_fingerprint] != fingerprint(parsed.body) ->
            {:error, :unit_changed}

          Unit.owned?(parsed, spec, opts) ->
            with :ok <- module.uninstall(spec, opts) do
              cleanup_status(spec, opts)
              {:ok, Map.put(base(spec), :action, "removed")}
            end

          true ->
            {:error, :unit_foreign}
        end

      _ ->
        {:error, :unit_foreign}
    end
  end

  defp mutate(operation, spec, manager, module, opts) do
    existing = Unit.read(spec.path, manager)

    cond do
      operation == :repair and existing == {:error, :not_found} ->
        {:ok, base(spec)}

      existing != {:error, :not_found} and not owned_existing?(existing, spec, opts) ->
        {:error, :unit_foreign}

      true ->
        observed = module.status(spec, opts)

        with {:ok, workers, opts} <- quiesce_controller_workers(spec, observed, opts),
             :ok <- stop_for_enrollment(spec, observed, module, opts),
             {:ok, adopted} <-
               Takeover.prepare(
                 spec,
                 if(opts[:invite_code], do: %{observed | pid: nil}, else: observed),
                 opts
               ),
             :ok <- enroll(spec, opts),
             {:ok, action} <-
               install_unit(spec, existing, observed, adopted, manager, module, opts) do
          item = wait_ready(spec, module, opts) |> Map.put(:action, action)

          with :ok <- cleanup_manual_record(spec, manager, item, opts) do
            if workers != [] and Readiness.ready?(item) do
              with :ok <- start_units(workers, opts), do: {:ok, item}
            else
              {:ok, item}
            end
          end
        end
    end
  end

  defp quiesce_controller_workers(%{role: "controller"} = spec, observed, opts) do
    with {:ok, snapshot} <- Takeover.controller_snapshot(spec, observed, opts),
         {:ok, workers} <- controller_workers(snapshot, opts) do
      with :ok <- stop_units(workers, opts) do
        opts = Keyword.put(opts, :controller_snapshot, snapshot)

        opts =
          if workers == [],
            do: opts,
            else: Keyword.put(opts, :wait, max(Keyword.get(opts, :wait, 120), 120))

        {:ok, workers, opts}
      end
    end
  end

  defp quiesce_controller_workers(_, _, opts), do: {:ok, [], opts}
  defp controller_workers(:supervised, _opts), do: {:ok, []}

  defp controller_workers(_, opts) do
    case running_units(opts) do
      units when is_list(units) -> {:ok, Enum.filter(units, &(&1.role == "worker"))}
      {:error, _} = error -> error
    end
  end

  defp cleanup_manual_record(_spec, "none", _item, _opts), do: :ok

  defp cleanup_manual_record(spec, _manager, item, opts) do
    if Readiness.ready?(item) do
      manual =
        shell_spec(spec.role, "none", Keyword.merge(opts, name: spec.name, port: spec.port))

      case Unit.read(manual.path, "none") do
        {:ok, parsed} ->
          if Unit.owned?(parsed, manual, opts) do
            File.rm(Manual.record_path(manual, opts))
            File.rm(manual.path)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp install_unit(spec, {:ok, parsed}, observed, adopted, manager, module, opts) do
    same = parsed.body == Unit.render(spec, manager)

    cond do
      same and observed.loaded and is_integer(observed.pid) and is_nil(opts[:invite_code]) ->
        {:ok, if(adopted, do: "adopted", else: "unchanged")}

      same and observed.loaded ->
        with :ok <- module.start(spec, opts), do: {:ok, "started"}

      true ->
        with :ok <- module.unload(spec, opts),
             :ok <- module.install(spec, opts) do
          {:ok,
           if(adopted or not managed_convention?(parsed.body, manager),
             do: "adopted",
             else: "updated"
           )}
        end
    end
  end

  defp install_unit(spec, _, _, adopted, _manager, module, opts) do
    with :ok <- module.install(spec, opts), do: {:ok, if(adopted, do: "adopted", else: "created")}
  end

  defp stop_for_enrollment(%{role: "worker"} = spec, %{pid: pid}, module, opts)
       when not is_nil(pid) do
    if opts[:invite_code], do: module.stop(spec, opts), else: :ok
  end

  defp stop_for_enrollment(_, _, _, _), do: :ok

  defp enroll(%{role: "worker"} = spec, opts) do
    if code = opts[:invite_code] do
      argv =
        case spec.argv do
          [_wrapper, "--" | args] -> args
          args -> args
        end

      [launcher | args] = argv

      env =
        System.get_env()
        |> Map.new(fn {name, _value} -> {name, nil} end)
        |> Map.merge(spec.env)
        |> Map.to_list()

      case Command.run(launcher, args ++ ["--invite-code-stdin", "--enroll-only"], opts,
             input: code <> "\n",
             env: env,
             timeout: 120_000
           ) do
        {_, 0} ->
          :ok

        {output, status} ->
          cond do
            enrollment_result?(output, "invite_rejected") ->
              {:error, :invite_rejected}

            status in [126, 127] ->
              {:error, {:enroll_start_failed, :launcher_unavailable}}

            enrollment_result?(output, "enroll_start_failed:address_in_use") ->
              {:error, {:enroll_start_failed, :address_in_use}}

            enrollment_result?(output, "enroll_start_failed:runtime_start_failed") ->
              {:error, {:enroll_start_failed, :runtime_start_failed}}

            true ->
              {:error, :enrollment_outcome_unknown}
          end
      end
    else
      :ok
    end
  end

  defp enroll(_, _), do: :ok

  defp enrollment_result?(output, result) do
    output |> String.split("\n", trim: true) |> List.last() == "lemon node join: " <> result
  end

  defp error_fields({:enroll_start_failed, reason})
       when reason in [:launcher_unavailable, :address_in_use, :runtime_start_failed],
       do: %{detail: "enroll_start_failed", reason: Atom.to_string(reason)}

  defp error_fields(reason), do: %{detail: to_string(reason)}

  defp wait_ready(spec, module, opts) do
    seconds = Keyword.get(opts, :wait, if(spec.role == "controller", do: 120, else: 60))
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    wait_ready(spec, module, opts, deadline, seconds > 0)
  end

  defp wait_ready(spec, module, opts, deadline, waiting) do
    item = report(spec, module, opts)

    cond do
      Readiness.ready?(item) ->
        item

      item.state in [
        "needs_reauthorization",
        "needs_enrollment",
        "conflict",
        "blocked",
        "foreign",
        "failed",
        "unknown"
      ] ->
        item

      System.monotonic_time(:millisecond) >= deadline ->
        if(waiting, do: %{item | detail: "timeout"}, else: item)

      true ->
        Process.sleep(200)
        wait_ready(spec, module, opts, deadline, waiting)
    end
  end

  defp report(spec, module, opts) do
    if File.exists?(spec.path) do
      observed = module.status(spec, opts)
      {state, detail} = Readiness.probe(spec, observed, opts)

      Map.merge(base(spec), %{
        installed: true,
        loaded: observed.loaded,
        state: state,
        pid: observed.pid,
        detail: detail
      })
    else
      base(spec)
    end
  end

  defp base(spec) do
    unit = %{
      role: spec.role,
      name: spec.name,
      label: spec.label,
      installed: false,
      loaded: false,
      state: "not_installed",
      pid: nil,
      version: nil,
      log: spec.log,
      detail: nil
    }

    if spec.role == "worker" do
      wrapper =
        case spec.argv do
          [wrapper, "--" | _] -> wrapper
          _ -> nil
        end

      Map.put(unit, :execWrapper, wrapper)
    else
      unit
    end
  end

  defp fingerprint(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp managed_convention?(body, "launchd"),
    do: String.contains?(body, "<key>SuccessfulExit</key>")

  defp managed_convention?(body, "systemd"),
    do: String.starts_with?(body, "# Managed by lemon service")

  defp managed_convention?(_, _), do: true

  defp manage_units(units, action, opts) do
    Enum.reduce_while(units, :ok, fn unit, :ok ->
      spec = unit.spec
      manager = unit.manager

      module =
        case manager do
          "launchd" -> Launchd
          "systemd" -> Systemd
          "none" -> Manual
        end

      result =
        Lock.with_lock(spec.label, opts, fn ->
          with {:ok, parsed} <- Unit.read(spec.path, manager),
               true <-
                 Unit.owned?(parsed, spec, opts) and fingerprint(parsed.body) == unit.fingerprint,
               :ok <- apply(module, action, [spec, opts]) do
            if action in [:start, :restart] do
              if Readiness.ready?(wait_ready(spec, module, opts)),
                do: :ok,
                else: {:error, :service_not_ready}
            else
              :ok
            end
          else
            false -> {:error, :unit_changed}
            error -> error
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp cleanup_status(%{role: "worker", name: name}, opts) do
    File.rm(LemonCore.WorkerStatus.path(name, home: Role.home(opts)))

    :ok
  end

  defp cleanup_status(%{role: "tunnel", name: name}, opts),
    do: File.rm(Path.join(Role.run_dir(opts), "tunnel-#{name}.json"))

  defp cleanup_status(_, _), do: :ok
end
