defmodule LemonWeb.OpsDashboard do
  @moduledoc false

  alias LemonCore.{ExecApprovalStore, Introspection}

  @recent_run_limit 10
  @run_detail_event_limit 500
  @child_lookup_limit 1_000
  @activity_event_limit 250
  @activity_recent_limit 5

  def snapshot do
    %{
      generated_at: DateTime.utc_now(),
      runtime: runtime_status(),
      build: build_status(),
      router: router_status(),
      provider: provider_status(),
      config: config_status(),
      active_sessions: active_sessions(),
      recent_runs: recent_runs(),
      pending_approvals: pending_approvals(),
      activity: observed_activity(),
      cron: cron_status(),
      skills: skills_status(),
      channels: channels_status(),
      support: support_commands(),
      planned_panels: planned_panels()
    }
  end

  def run_detail(run_id) when is_binary(run_id) and run_id != "" do
    events = run_events(run_id)

    %{
      run_id: run_id,
      summary: run_summary(run_id, events),
      events: events,
      event_counts: event_counts(events),
      tool_events: Enum.filter(events, &tool_event?/1),
      failures: Enum.filter(events, &failure_event?/1),
      children: child_runs(run_id),
      graph: run_graph(run_id),
      pending_approvals: pending_approvals_for_run(run_id),
      support: support_commands()
    }
  end

  def run_detail(_run_id) do
    %{
      run_id: nil,
      summary: %{},
      events: [],
      event_counts: %{},
      tool_events: [],
      failures: [],
      children: [],
      graph: nil,
      pending_approvals: [],
      support: support_commands()
    }
  end

  def resolve_approval(approval_id, decision) when is_binary(approval_id) do
    with {:ok, decision} <- normalize_approval_decision(decision) do
      :ok = LemonCore.ExecApprovals.resolve(approval_id, decision)
      :ok
    end
  end

  def resolve_approval(_approval_id, _decision), do: {:error, :invalid_approval}

  def create_cron_job(params) when is_map(params) do
    case cron_manager_call(:add, [cron_create_params(params)]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def create_cron_job(_params), do: {:error, :invalid_cron_job}

  def update_cron_job(job_id, params) when is_binary(job_id) and is_map(params) do
    case cron_manager_call(:update, [job_id, cron_update_params(params)]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def update_cron_job(_job_id, _params), do: {:error, :invalid_cron_update}

  def delete_cron_job(job_id) when is_binary(job_id) do
    case cron_manager_call(:remove, [job_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def delete_cron_job(_job_id), do: {:error, :invalid_cron_job}

  def set_cron_enabled(job_id, enabled) when is_binary(job_id) and is_boolean(enabled) do
    case cron_manager_call(:update, [job_id, %{enabled: enabled}]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def set_cron_enabled(_job_id, _enabled), do: {:error, :invalid_cron_update}

  def run_cron_now(job_id) when is_binary(job_id) do
    case cron_manager_call(:run_now, [job_id]) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def run_cron_now(_job_id), do: {:error, :invalid_cron_job}

  def set_skill_enabled(skill_key, enabled, opts \\ [])

  def set_skill_enabled(skill_key, enabled, opts)
      when is_binary(skill_key) and is_boolean(enabled) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    global = Keyword.get(opts, :global, true)
    function = if enabled, do: :enable, else: :disable

    case skills_module_call(["Config"], function, [skill_key, [cwd: cwd, global: global]]) do
      :ok ->
        _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  def set_skill_enabled(_skill_key, _enabled, _opts), do: {:error, :invalid_skill_update}

  def install_skill(source, opts \\ [])

  def install_skill(source, opts) when is_binary(source) do
    source = String.trim(source)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    global = Keyword.get(opts, :global, true)
    force = Keyword.get(opts, :force, false)

    if source == "" do
      {:error, :invalid_skill_source}
    else
      case skills_module_call(["Installer"], :install, [
             source,
             [cwd: cwd, global: global, force: force, approve: true]
           ]) do
        {:ok, _entry} ->
          _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
          :ok

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  def install_skill(_source, _opts), do: {:error, :invalid_skill_source}

  def update_skill(skill_key, opts \\ [])

  def update_skill(skill_key, opts) when is_binary(skill_key) do
    skill_key = String.trim(skill_key)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    force = Keyword.get(opts, :force, false)

    if skill_key == "" do
      {:error, :invalid_skill_update}
    else
      case skills_module_call(["Installer"], :update, [
             skill_key,
             [cwd: cwd, force: force, approve: true]
           ]) do
        {:ok, _entry} ->
          _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
          :ok

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  def update_skill(_skill_key, _opts), do: {:error, :invalid_skill_update}

  def disconnect_channel(channel_id) when is_binary(channel_id) and channel_id != "" do
    case channel_registry_call(:logout, [channel_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def disconnect_channel(_channel_id), do: {:error, :invalid_channel}

  def reconnect_channel(channel_id) when is_binary(channel_id) and channel_id != "" do
    with {:ok, adapter_module, opts} <- configured_channel_adapter(channel_id) do
      case channels_application_call(:register_and_start_adapter, [adapter_module, opts]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  def reconnect_channel(_channel_id), do: {:error, :invalid_channel}

  def set_channel_config_enabled(channel_id, enabled)
      when is_binary(channel_id) and is_boolean(enabled) do
    case gateway_transport_config_key(channel_id) do
      nil ->
        {:error, :channel_not_configurable}

      key ->
        with :ok <- write_gateway_boolean(key, enabled),
             :ok <- reload_config() do
          :ok
        end
    end
  end

  def set_channel_config_enabled(_channel_id, _enabled), do: {:error, :invalid_channel}

  def update_default_config(params) when is_map(params) do
    fields = [
      {"provider", param_string(params, "provider"), :string},
      {"model", param_string(params, "model"), :string},
      {"thinking_level", param_string(params, "thinking_level"), :string},
      {"engine", param_string(params, "engine"), :string}
    ]

    with :ok <- write_table_fields("defaults", fields),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_default_config(_params), do: {:error, :invalid_default_config}

  def update_provider_config(provider_id, params)
      when is_binary(provider_id) and is_map(params) do
    provider_id = String.trim(provider_id)

    with :ok <- validate_provider_id(provider_id),
         :ok <- write_table_fields("providers.#{provider_id}", provider_config_fields(params)),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_provider_config(_provider_id, _params), do: {:error, :invalid_provider_config}

  def update_channel_gateway_defaults(params) when is_map(params) do
    with :ok <- write_gateway_defaults(params),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_channel_gateway_defaults(_params), do: {:error, :invalid_gateway_config}

  def update_channel_telegram_config(params) when is_map(params) do
    with {:ok, fields} <- telegram_config_fields(params),
         :ok <- write_table_fields("gateway.telegram", fields),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_channel_telegram_config(_params), do: {:error, :invalid_telegram_config}

  def create_channel_binding(params) when is_map(params) do
    with {:ok, binding} <- channel_binding_params(params),
         :ok <- write_gateway_bindings(current_channel_bindings() ++ [binding]),
         :ok <- reload_config() do
      :ok
    end
  end

  def create_channel_binding(_params), do: {:error, :invalid_channel_binding}

  def update_channel_binding(index, params) when is_map(params) do
    with {:ok, index} <- parse_binding_index(index),
         bindings <- current_channel_bindings(),
         true <- index < length(bindings),
         {:ok, binding} <- channel_binding_params(params),
         updated <- List.replace_at(bindings, index, binding),
         :ok <- write_gateway_bindings(updated),
         :ok <- reload_config() do
      :ok
    else
      false -> {:error, :invalid_channel_binding}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_channel_binding(_index, _params), do: {:error, :invalid_channel_binding}

  def delete_channel_binding(index) do
    with {:ok, index} <- parse_binding_index(index),
         bindings <- current_channel_bindings(),
         true <- index < length(bindings),
         updated <- List.delete_at(bindings, index),
         :ok <- write_gateway_bindings(updated),
         :ok <- reload_config() do
      :ok
    else
      false -> {:error, :invalid_channel_binding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_status do
    LemonCore.Runtime.Boot.status(:runtime_full)
  rescue
    error -> %{status: :unknown, apps: [], missing: [], error: Exception.message(error)}
  catch
    kind, reason -> %{status: :unknown, apps: [], missing: [], error: inspect({kind, reason})}
  end

  defp build_status do
    LemonCore.BuildInfo.current()
  rescue
    error -> %{runtime_mode: "unknown", error: Exception.message(error)}
  catch
    kind, reason -> %{runtime_mode: "unknown", error: inspect({kind, reason})}
  end

  defp router_status do
    LemonRouter.Health.status()
  rescue
    error -> %{ok: false, checks: [], error: Exception.message(error)}
  catch
    kind, reason -> %{ok: false, checks: [], error: inspect({kind, reason})}
  end

  defp provider_status do
    checks =
      LemonCore.Doctor.Checks.Providers.run()
      |> Enum.map(&format_check/1)

    secrets = LemonCore.Secrets.status()

    %{
      checks: checks,
      ok?: Enum.all?(checks, &(&1.status == "pass")),
      secrets: %{
        configured: secrets.configured,
        source: secrets.source,
        keychain_available: secrets.keychain_available,
        env_fallback: secrets.env_fallback,
        secret_count: secrets.count
      }
    }
  rescue
    error ->
      %{checks: [], ok?: false, error: Exception.message(error), secrets: %{}}
  catch
    kind, reason ->
      %{checks: [], ok?: false, error: inspect({kind, reason}), secrets: %{}}
  end

  defp config_status do
    config = LemonCore.Config.load()

    %{
      defaults: format_default_config(config),
      providers: provider_config_entries(config.providers || [])
    }
  rescue
    error -> %{defaults: %{}, providers: [], error: Exception.message(error)}
  catch
    kind, reason -> %{defaults: %{}, providers: [], error: inspect({kind, reason})}
  end

  defp format_default_config(config) do
    default_profile = Map.get(config.agents || %{}, "default", %{})

    %{
      provider: get_map(config.agent, :default_provider),
      model: get_map(config.agent, :default_model),
      thinking_level: format_activity_value(get_map(config.agent, :default_thinking_level)),
      engine: get_map(default_profile, :default_engine)
    }
  end

  defp provider_config_entries(providers) when is_map(providers) do
    configured_ids = Map.keys(providers) |> Enum.map(&to_string/1)

    (known_provider_summaries() ++ Enum.map(configured_ids, &%{id: &1, display_name: &1}))
    |> Enum.reduce(%{}, fn provider, acc -> Map.put(acc, provider.id, provider) end)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn provider ->
      config = Map.get(providers, provider.id, %{}) || %{}

      %{
        id: provider.id,
        display_name: provider.display_name || provider.id,
        configured?: map_size(config) > 0,
        auth_source: provider_field(config, :auth_source),
        api_key_secret: provider_field(config, :api_key_secret),
        oauth_secret: provider_field(config, :oauth_secret),
        base_url: provider_field(config, :base_url),
        has_direct_api_key?: provider_field(config, :api_key) not in [nil, ""]
      }
    end)
  end

  defp provider_config_entries(_providers), do: []

  defp known_provider_summaries do
    LemonCore.Onboarding.Providers.list()
    |> Enum.map(fn provider ->
      %{id: provider.id, display_name: provider.display_name}
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp provider_field(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp active_sessions do
    LemonCore.RouterBridge.list_active_sessions()
    |> List.wrap()
    |> Enum.map(&format_active_session/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp recent_runs do
    Introspection.list(event_type: :run_completed, limit: @recent_run_limit)
    |> Enum.map(&format_run_event/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp run_events(run_id) do
    Introspection.list(run_id: run_id, limit: @run_detail_event_limit)
    |> Enum.map(&format_timeline_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.ts_ms || 0), :asc)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp child_runs(run_id) do
    Introspection.list(limit: @child_lookup_limit)
    |> Enum.filter(&(get_map(&1, :parent_run_id) == run_id))
    |> Enum.reduce(%{}, fn event, acc ->
      child_run_id = get_map(event, :run_id)

      if is_binary(child_run_id) and child_run_id != "" do
        Map.update(acc, child_run_id, child_run_summary(child_run_id, event), fn existing ->
          merge_child_run(existing, event)
        end)
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&(&1.started_at_ms || 0), :asc)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp run_graph(root_run_id) do
    events =
      Introspection.list(limit: @child_lookup_limit)
      |> Enum.map(&format_timeline_event/1)
      |> Enum.reject(&is_nil/1)

    events_by_run =
      events
      |> Enum.filter(&(is_binary(&1.run_id) and &1.run_id != ""))
      |> Enum.group_by(& &1.run_id)

    summaries =
      Map.new(events_by_run, fn {run_id, run_events} ->
        sorted = Enum.sort_by(run_events, &(&1.ts_ms || 0), :asc)
        {run_id, run_summary(run_id, sorted)}
      end)

    children_by_parent =
      events
      |> Enum.reduce(%{}, fn event, acc ->
        child_run_id = event.run_id
        parent_run_id = event.parent_run_id

        if is_binary(child_run_id) and child_run_id != "" and is_binary(parent_run_id) and
             parent_run_id != "" do
          Map.update(
            acc,
            parent_run_id,
            MapSet.new([child_run_id]),
            &MapSet.put(&1, child_run_id)
          )
        else
          acc
        end
      end)
      |> Map.new(fn {parent_run_id, child_ids} ->
        {parent_run_id, child_ids |> MapSet.to_list() |> Enum.sort()}
      end)

    build_run_tree(root_run_id, summaries, children_by_parent, MapSet.new())
  rescue
    _ -> %{run_id: root_run_id, status: "unknown", children: []}
  catch
    _, _ -> %{run_id: root_run_id, status: "unknown", children: []}
  end

  defp pending_approvals do
    now_ms = LemonCore.Clock.now_ms()

    ExecApprovalStore.list_pending()
    |> Enum.map(fn {_id, pending} -> pending end)
    |> Enum.filter(&approval_active?(&1, now_ms))
    |> Enum.map(&format_pending_approval/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp format_active_session(%{session_key: session_key, run_id: run_id}) do
    %{session_key: session_key, run_id: run_id}
  end

  defp format_active_session(%{"sessionKey" => session_key, "runId" => run_id}) do
    %{session_key: session_key, run_id: run_id}
  end

  defp format_active_session({session_key, _pid, meta}) when is_map(meta) do
    %{session_key: session_key, run_id: meta[:run_id] || meta["run_id"]}
  end

  defp format_active_session(_), do: nil

  defp format_run_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    ok = payload[:ok] || payload["ok"]
    error = payload[:error] || payload["error"]

    %{
      run_id: event[:run_id] || event["run_id"],
      session_key: event[:session_key] || event["session_key"],
      agent_id: event[:agent_id] || event["agent_id"],
      engine: event[:engine] || event["engine"],
      completed_at_ms: event[:ts_ms] || event["ts_ms"],
      ok?: ok == true,
      error: error
    }
  end

  defp format_run_event(_), do: nil

  defp format_check(%{name: name, status: status, message: message, remediation: remediation}) do
    %{
      name: name,
      status: normalize_event_type(status),
      message: message,
      remediation: remediation
    }
  end

  defp format_check(other) do
    %{name: "unknown", status: "warn", message: inspect(other), remediation: nil}
  end

  defp format_timeline_event(event) when is_map(event) do
    payload = get_map(event, :payload, %{})
    event_type = normalize_event_type(get_map(event, :event_type))

    %{
      event_id: get_map(event, :event_id),
      event_type: event_type,
      ts_ms: get_map(event, :ts_ms),
      run_id: get_map(event, :run_id),
      session_key: get_map(event, :session_key),
      agent_id: get_map(event, :agent_id),
      parent_run_id: get_map(event, :parent_run_id),
      engine: get_map(event, :engine),
      provenance: normalize_event_type(get_map(event, :provenance)),
      tool: payload_tool(payload),
      ok?: payload_ok?(payload),
      error: payload_error(payload),
      preview: payload_preview(payload)
    }
  end

  defp format_timeline_event(_), do: nil

  defp format_pending_approval(pending) when is_map(pending) do
    %{
      id: pending[:id] || pending["id"],
      run_id: pending[:run_id] || pending["run_id"],
      session_key: pending[:session_key] || pending["session_key"],
      agent_id: pending[:agent_id] || pending["agent_id"],
      tool: pending[:tool] || pending["tool"],
      rationale: pending[:rationale] || pending["rationale"],
      requested_at_ms: pending[:requested_at_ms] || pending["requested_at_ms"],
      expires_at_ms: approval_expires_at(pending)
    }
  end

  defp format_cron_job(id, job) when is_map(job) do
    %{
      id: get_map(job, :id, id),
      name: get_map(job, :name, "unnamed"),
      schedule: get_map(job, :schedule),
      enabled?: get_map(job, :enabled, true) == true,
      agent_id: get_map(job, :agent_id),
      session_key: get_map(job, :session_key),
      timezone: get_map(job, :timezone, "UTC"),
      last_run_at_ms: get_map(job, :last_run_at_ms),
      next_run_at_ms: get_map(job, :next_run_at_ms),
      created_at_ms: get_map(job, :created_at_ms),
      updated_at_ms: get_map(job, :updated_at_ms)
    }
  end

  defp format_cron_job(id, job) do
    %{
      id: id,
      name: inspect(job),
      schedule: nil,
      enabled?: false,
      agent_id: nil,
      session_key: nil,
      timezone: nil,
      created_at_ms: nil,
      updated_at_ms: nil
    }
  end

  defp format_cron_run(id, run) when is_map(run) do
    %{
      id: get_map(run, :id, id),
      job_id: get_map(run, :job_id),
      run_id: get_map(run, :run_id),
      status: normalize_event_type(get_map(run, :status)) || "unknown",
      triggered_by: normalize_event_type(get_map(run, :triggered_by)),
      started_at_ms: get_map(run, :started_at_ms),
      completed_at_ms: get_map(run, :completed_at_ms),
      duration_ms: get_map(run, :duration_ms),
      error: get_map(run, :error)
    }
  end

  defp format_cron_run(id, run) do
    %{id: id, job_id: nil, run_id: nil, status: inspect(run), triggered_by: nil}
  end

  defp format_channel_binding(binding, index) when is_map(binding) do
    %{
      index: index,
      transport: get_map(binding, :transport),
      chat_id: get_map(binding, :chat_id),
      topic_id: get_map(binding, :topic_id),
      agent_id: get_map(binding, :agent_id),
      default_engine: get_map(binding, :default_engine),
      project: get_map(binding, :project)
    }
  end

  defp format_channel_binding(binding, index) do
    %{index: index, transport: "unknown", chat_id: inspect(binding), topic_id: nil, agent_id: nil}
  end

  defp approval_expires_at(pending) when is_map(pending) do
    cond do
      Map.has_key?(pending, :expires_at_ms) -> pending[:expires_at_ms]
      Map.has_key?(pending, "expires_at_ms") -> pending["expires_at_ms"]
      true -> 0
    end
  end

  defp approval_expires_at(_), do: 0

  defp approval_active?(pending, now_ms) do
    case approval_expires_at(pending) do
      nil -> true
      expires_at_ms when is_integer(expires_at_ms) -> expires_at_ms > now_ms
      _ -> false
    end
  end

  defp pending_approvals_for_run(run_id) do
    pending_approvals()
    |> Enum.filter(&(&1.run_id == run_id))
  end

  defp observed_activity do
    events =
      Introspection.list(limit: @activity_event_limit)
      |> Enum.map(&format_timeline_event/1)
      |> Enum.reject(&is_nil/1)

    [:cron, :skills, :channels, :memory, :logs]
    |> Enum.map(fn category ->
      category_events = Enum.filter(events, &(activity_category(&1) == category))

      %{
        category: Atom.to_string(category),
        count: length(category_events),
        recent:
          category_events
          |> Enum.sort_by(&(&1.ts_ms || 0), :desc)
          |> Enum.take(@activity_recent_limit)
      }
    end)
    |> then(&%{total_events: length(events), categories: &1})
  rescue
    _ -> %{total_events: 0, categories: []}
  catch
    _, _ -> %{total_events: 0, categories: []}
  end

  defp cron_status do
    jobs =
      :cron_jobs
      |> LemonCore.Store.list()
      |> Enum.map(fn {id, job} -> format_cron_job(id, job) end)
      |> Enum.sort_by(&(&1.updated_at_ms || &1.created_at_ms || 0), :desc)

    runs =
      :cron_runs
      |> LemonCore.Store.list()
      |> Enum.map(fn {id, run} -> format_cron_run(id, run) end)
      |> Enum.sort_by(&(&1.started_at_ms || &1.completed_at_ms || 0), :desc)

    %{
      jobs: jobs,
      recent_runs: Enum.take(runs, 5),
      enabled_count: Enum.count(jobs, & &1.enabled?),
      failed_run_count: Enum.count(runs, &(&1.status in ["failed", "timeout"]))
    }
  rescue
    _ -> %{jobs: [], recent_runs: [], enabled_count: 0, failed_run_count: 0}
  catch
    _, _ -> %{jobs: [], recent_runs: [], enabled_count: 0, failed_run_count: 0}
  end

  defp skills_status do
    checks =
      LemonCore.Doctor.Checks.Skills.run()
      |> Enum.map(&format_check/1)

    skills = skill_entries()

    %{
      checks: checks,
      ok?: Enum.all?(checks, &(&1.status in ["pass", "skip"])),
      entries: skills,
      installed_count: length(skills),
      enabled_count: Enum.count(skills, & &1.enabled?),
      blocked_count: Enum.count(skills, &(&1.audit_status == "block")),
      missing_count: Enum.count(skills, &(&1.missing != []))
    }
  rescue
    error ->
      %{checks: [], ok?: false, entries: [], error: Exception.message(error)}
  catch
    kind, reason -> %{checks: [], ok?: false, entries: [], error: inspect({kind, reason})}
  end

  defp channels_status do
    gateway = LemonCore.Config.load().gateway || %{}
    configured_transports = configured_channel_transports(gateway)
    runtime = channel_runtime_status()
    runtime_by_id = Map.new(runtime.adapters, &{&1.name, &1})
    configured_by_id = Map.new(configured_transports, &{&1.name, &1})

    transports =
      configured_by_id
      |> Map.keys()
      |> Kernel.++(Map.keys(runtime_by_id))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn name ->
        configured = Map.get(configured_by_id, name, %{name: name, enabled?: false})
        runtime_adapter = Map.get(runtime_by_id, name, %{})
        runtime_status = runtime_adapter[:runtime_status] || "not_registered"

        configured
        |> Map.merge(%{
          configured?:
            configured[:app_configured?] == true or MapSet.member?(runtime.configured, name),
          connected?: MapSet.member?(runtime.connected, name) or runtime_status == "running",
          runtime_status: runtime_status,
          reconnectable?: configured[:app_configured?] == true and runtime_status != "running",
          account_id: runtime_adapter[:account_id],
          capabilities: runtime_adapter[:capabilities] || %{}
        })
      end)

    bindings =
      gateway
      |> Map.get(:bindings, [])
      |> Enum.with_index()
      |> Enum.map(fn {binding, index} -> format_channel_binding(binding, index) end)

    %{
      transports: transports,
      enabled_count: Enum.count(transports, & &1.enabled?),
      running_count: Enum.count(transports, &(&1.runtime_status == "running")),
      bindings: bindings,
      gateway: format_gateway_channel_config(gateway),
      telegram: format_telegram_channel_config(gateway)
    }
  rescue
    error ->
      %{
        transports: [],
        enabled_count: 0,
        running_count: 0,
        bindings: [],
        gateway: %{},
        telegram: %{},
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        transports: [],
        enabled_count: 0,
        running_count: 0,
        bindings: [],
        gateway: %{},
        telegram: %{},
        error: inspect({kind, reason})
      }
  end

  defp format_gateway_channel_config(gateway) do
    %{
      default_engine: Map.get(gateway, :default_engine),
      default_cwd: Map.get(gateway, :default_cwd),
      auto_resume?: Map.get(gateway, :auto_resume) == true
    }
  end

  defp format_telegram_channel_config(gateway) do
    telegram = Map.get(gateway, :telegram, %{}) || %{}

    %{
      bot_token_secret: get_map(telegram, :bot_token_secret),
      allowed_chat_ids: get_map(telegram, :allowed_chat_ids, []) |> List.wrap(),
      deny_unbound_chats?: get_map(telegram, :deny_unbound_chats, false) == true
    }
  end

  defp configured_channel_transports(gateway) do
    gateway_transports =
      [
        {"telegram", :enable_telegram},
        {"discord", :enable_discord},
        {"farcaster", :enable_farcaster},
        {"email", :enable_email},
        {"xmtp", :enable_xmtp},
        {"webhook", :enable_webhook}
      ]
      |> Enum.map(fn {name, field} ->
        %{
          name: name,
          enabled?: Map.get(gateway, field) == true,
          configurable?: true,
          config_key: Atom.to_string(field)
        }
      end)

    app_transports = configured_channel_adapter_summaries()

    (gateway_transports ++ app_transports)
    |> Enum.reduce(%{}, fn transport, acc ->
      Map.update(acc, transport.name, transport, fn existing ->
        existing
        |> Map.merge(transport)
        |> Map.update(:enabled?, existing.enabled?, &(&1 || existing.enabled?))
      end)
    end)
    |> Map.values()
  end

  defp configured_channel_adapter_summaries do
    :lemon_channels
    |> Application.get_env(:adapters, [])
    |> Enum.map(&normalize_configured_channel_adapter/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_configured_channel_adapter({adapter_module, _opts})
       when is_atom(adapter_module) do
    configured_channel_adapter_summary(adapter_module)
  end

  defp normalize_configured_channel_adapter(adapter_module) when is_atom(adapter_module) do
    configured_channel_adapter_summary(adapter_module)
  end

  defp normalize_configured_channel_adapter(_), do: nil

  defp configured_channel_adapter_summary(adapter_module) do
    case adapter_id(adapter_module) do
      id when is_binary(id) and id != "" ->
        %{name: id, enabled?: true, app_configured?: true, configurable?: false}

      _ ->
        nil
    end
  end

  defp configured_channel_adapter(channel_id) do
    :lemon_channels
    |> Application.get_env(:adapters, [])
    |> Enum.find_value(fn
      {adapter_module, opts} when is_atom(adapter_module) and is_list(opts) ->
        if adapter_id(adapter_module) == channel_id, do: {:ok, adapter_module, opts}

      adapter_module when is_atom(adapter_module) ->
        if adapter_id(adapter_module) == channel_id, do: {:ok, adapter_module, []}

      _ ->
        nil
    end)
    |> case do
      nil -> {:error, :channel_not_configured}
      result -> result
    end
  end

  defp adapter_id(adapter_module) when is_atom(adapter_module) do
    with {:module, ^adapter_module} <- Code.ensure_loaded(adapter_module),
         true <- function_exported?(adapter_module, :id, 0) do
      apply(adapter_module, :id, [])
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp channel_runtime_status do
    registry_status =
      case channel_registry_call(:status, []) do
        %{configured: configured, connected: connected} ->
          %{
            configured: configured |> List.wrap() |> MapSet.new(),
            connected: connected |> List.wrap() |> MapSet.new()
          }

        _ ->
          %{configured: MapSet.new(), connected: MapSet.new()}
      end

    adapters =
      case channel_registry_call(:list, []) do
        adapters when is_list(adapters) ->
          adapters
          |> Enum.map(&format_channel_runtime_adapter/1)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{
      adapters: adapters,
      configured: registry_status.configured,
      connected: registry_status.connected
    }
  end

  defp format_channel_runtime_adapter({channel_id, info}) when is_map(info) do
    %{
      name: channel_id,
      runtime_status: format_activity_value(info[:status] || info["status"] || "unknown"),
      account_id: info[:account_id] || info["account_id"],
      capabilities: info[:capabilities] || info["capabilities"] || %{}
    }
  end

  defp format_channel_runtime_adapter(info) when is_map(info) do
    %{
      name: info[:channel_id] || info["channelId"] || info[:id] || info["id"],
      runtime_status: format_activity_value(info[:status] || info["status"] || "unknown"),
      account_id: info[:account_id] || info["accountId"],
      capabilities: info[:capabilities] || info["capabilities"] || %{}
    }
  end

  defp format_channel_runtime_adapter(_), do: nil

  defp cron_manager_call(function, args) do
    module = Module.concat(["Lemon" <> "Automation", "CronManager"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :cron_manager_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp skills_module_call(parts, function, args) do
    module = Module.concat(["Lemon" <> "Skills" | parts])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :skills_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp channel_registry_call(function, args) do
    module = Module.concat(["Lemon" <> "Channels", "Registry"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :channel_registry_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp channels_application_call(function, args) do
    module = Module.concat(["Lemon" <> "Channels", "Application"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :channels_application_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp gateway_transport_config_key("telegram"), do: "enable_telegram"
  defp gateway_transport_config_key("discord"), do: "enable_discord"
  defp gateway_transport_config_key("farcaster"), do: "enable_farcaster"
  defp gateway_transport_config_key("email"), do: "enable_email"
  defp gateway_transport_config_key("xmtp"), do: "enable_xmtp"
  defp gateway_transport_config_key("webhook"), do: "enable_webhook"
  defp gateway_transport_config_key(_), do: nil

  defp write_gateway_boolean(key, enabled) do
    path = LemonCore.Config.global_path()
    content = if File.exists?(path), do: File.read!(path), else: ""

    updated =
      LemonCore.Config.TomlPatch.upsert_raw_line(
        content,
        "gateway",
        key,
        "#{key} = #{enabled}"
      )

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, updated)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp write_gateway_defaults(params) do
    fields = [
      {"default_engine", param_string(params, "default_engine"), :string},
      {"default_cwd", param_string(params, "default_cwd"), :string},
      {"auto_resume", boolean_param(params, "auto_resume"), :boolean}
    ]

    write_table_fields("gateway", fields)
  end

  defp telegram_config_fields(params) do
    with {:ok, allowed_chat_ids} <-
           parse_allowed_chat_ids(param_string(params, "allowed_chat_ids")) do
      {:ok,
       [
         {"bot_token_secret", param_string(params, "bot_token_secret"), :string},
         {"allowed_chat_ids", allowed_chat_ids, :integer_array},
         {"deny_unbound_chats", boolean_param(params, "deny_unbound_chats"), :boolean}
       ]}
    end
  end

  defp provider_config_fields(params) do
    [
      {"auth_source", normalize_auth_source(param_string(params, "auth_source")), :string},
      {"api_key_secret", param_string(params, "api_key_secret"), :string},
      {"oauth_secret", param_string(params, "oauth_secret"), :string},
      {"base_url", param_string(params, "base_url"), :string}
    ]
  end

  defp normalize_auth_source(nil), do: nil
  defp normalize_auth_source(value) when value in ["api_key", "oauth"], do: value
  defp normalize_auth_source(_value), do: nil

  defp validate_provider_id(provider_id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, provider_id) do
      :ok
    else
      {:error, :invalid_provider_id}
    end
  end

  defp write_table_fields(table, fields) do
    patch_config_file(fn content ->
      Enum.reduce(fields, content, fn
        {key, nil, _type}, acc ->
          LemonCore.Config.TomlPatch.delete_key(acc, table, key)

        {key, [], :integer_array}, acc ->
          LemonCore.Config.TomlPatch.delete_key(acc, table, key)

        {key, value, :string}, acc ->
          LemonCore.Config.TomlPatch.upsert_raw_line(acc, table, key, raw_string_line(key, value))

        {key, value, :boolean}, acc when is_boolean(value) ->
          LemonCore.Config.TomlPatch.upsert_raw_line(acc, table, key, "#{key} = #{value}")

        {key, value, :integer_array}, acc when is_list(value) ->
          LemonCore.Config.TomlPatch.upsert_raw_line(
            acc,
            table,
            key,
            raw_integer_array_line(key, value)
          )
      end)
    end)
  end

  defp write_gateway_bindings(bindings) when is_list(bindings) do
    patch_config_file(fn content ->
      content
      |> drop_gateway_bindings()
      |> append_gateway_bindings(bindings)
    end)
  end

  defp patch_config_file(fun) do
    path = LemonCore.Config.global_path()
    content = if File.exists?(path), do: File.read!(path), else: ""
    updated = fun.(content)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, updated)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp raw_string_line(key, value), do: ~s(#{key} = #{toml_string(value)})

  defp raw_integer_array_line(key, values) do
    rendered = values |> Enum.map(&to_string/1) |> Enum.join(", ")
    "#{key} = [#{rendered}]"
  end

  defp toml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp reload_config do
    cwd = File.cwd!()
    _ = LemonCore.ConfigCache.invalidate(cwd)
    _ = LemonCore.ConfigCache.invalidate(nil)
    _ = LemonCore.Config.reload(cwd, cache: false)

    if is_pid(Process.whereis(LemonCore.ConfigReloader)) do
      case LemonCore.ConfigReloader.reload(
             cwd: cwd,
             force: true,
             reason: :web_ops_channel_config
           ) do
        {:ok, _result} -> :ok
        {:error, :reload_in_progress} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp skill_entries do
    cwd = File.cwd!()

    case skills_module_call(["Registry"], :list, [[cwd: cwd, refresh: true]]) do
      entries when is_list(entries) ->
        entries
        |> Enum.map(&format_skill_entry(&1, cwd))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp format_skill_entry(entry, cwd) do
    status =
      case skills_module_call(["Status"], :check_entry, [entry, [cwd: cwd]]) do
        status when is_map(status) -> status
        _ -> %{}
      end

    %{
      key: entry_value(entry, :key),
      name: entry_value(entry, :name) || entry_value(entry, :key),
      description: entry_value(entry, :description),
      source: format_activity_value(entry_value(entry, :source)),
      path: entry_value(entry, :path),
      enabled?: not status_value(status, :disabled, false),
      activation_state: format_activity_value(status_value(status, :activation_state, "unknown")),
      source_kind: format_activity_value(entry_value(entry, :source_kind) || "unknown"),
      source_id: entry_value(entry, :source_id),
      trust_level: format_activity_value(entry_value(entry, :trust_level) || "unknown"),
      audit_status: format_activity_value(entry_value(entry, :audit_status) || "unknown"),
      content_hash: entry_value(entry, :content_hash),
      bundle_hash: entry_value(entry, :bundle_hash),
      upstream_hash: entry_value(entry, :upstream_hash),
      installed_at: format_time_value(entry_value(entry, :installed_at)),
      updated_at: format_time_value(entry_value(entry, :updated_at)),
      required_bins: required_bins(entry_value(entry, :manifest)),
      missing: missing_requirements(status)
    }
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp entry_value(entry, field) when is_map(entry) do
    Map.get(entry, field) || Map.get(entry, Atom.to_string(field))
  end

  defp entry_value(_, _), do: nil

  defp status_value(status, field, default) when is_map(status) do
    Map.get(status, field) || Map.get(status, Atom.to_string(field), default)
  end

  defp status_value(_, _, default), do: default

  defp required_bins(manifest) when is_map(manifest) do
    manifest
    |> manifest_get("requires", %{})
    |> manifest_get("bins", [])
    |> List.wrap()
    |> Enum.map(fn
      bin when is_binary(bin) -> bin
      bin when is_map(bin) -> manifest_get(bin, "name", nil)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp required_bins(_), do: []

  defp manifest_get(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key), default)
  end

  defp manifest_get(_, _, default), do: default

  defp missing_requirements(status) when is_map(status) do
    []
    |> Kernel.++(List.wrap(status_value(status, :missing_bins, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_config, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_env_vars, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_tools, [])))
    |> Enum.uniq()
  end

  defp missing_requirements(_), do: []

  defp cron_create_params(params) do
    %{}
    |> maybe_put(:name, param_string(params, "name"))
    |> maybe_put(:schedule, param_string(params, "schedule"))
    |> maybe_put(:agent_id, param_string(params, "agent_id"))
    |> maybe_put(:session_key, param_string(params, "session_key"))
    |> maybe_put(:prompt, param_string(params, "prompt"))
    |> maybe_put(:timezone, param_string(params, "timezone"))
    |> Map.put(:enabled, truthy_param?(Map.get(params, "enabled")))
  end

  defp cron_update_params(params) do
    %{}
    |> maybe_put(:name, param_string(params, "name"))
    |> maybe_put(:schedule, param_string(params, "schedule"))
    |> maybe_put(:prompt, param_string(params, "prompt"))
    |> maybe_put(:timezone, param_string(params, "timezone"))
  end

  defp param_string(params, key) do
    value = Map.get(params, key) || Map.get(params, String.to_atom(key))

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      nil ->
        nil

      value ->
        to_string(value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp boolean_param(params, key) do
    if Map.has_key?(params, key) or Map.has_key?(params, String.to_atom(key)) do
      truthy_param?(Map.get(params, key) || Map.get(params, String.to_atom(key)))
    end
  end

  defp truthy_param?(value), do: value in [true, "true", "on", "1", 1]

  defp current_channel_bindings do
    gateway = LemonCore.Config.load().gateway || %{}

    gateway
    |> Map.get(:bindings, [])
    |> List.wrap()
    |> Enum.map(&normalize_channel_binding/1)
    |> Enum.reject(&is_nil/1)
  end

  defp channel_binding_params(params) do
    binding =
      %{
        transport: param_string(params, "transport") || "telegram",
        chat_id: parse_required_binding_value(param_string(params, "chat_id")),
        topic_id: parse_optional_binding_value(param_string(params, "topic_id")),
        agent_id: param_string(params, "agent_id") || "default",
        default_engine: param_string(params, "default_engine"),
        project: param_string(params, "project")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if binding[:chat_id] do
      {:ok, binding}
    else
      {:error, :invalid_channel_binding}
    end
  end

  defp normalize_channel_binding(binding) when is_map(binding) do
    %{
      transport: get_map(binding, :transport),
      chat_id: get_map(binding, :chat_id),
      topic_id: get_map(binding, :topic_id),
      agent_id: get_map(binding, :agent_id),
      default_engine: get_map(binding, :default_engine),
      project: get_map(binding, :project)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_channel_binding(_binding), do: nil

  defp parse_binding_index(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp parse_binding_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_channel_binding}
    end
  end

  defp parse_binding_index(_index), do: {:error, :invalid_channel_binding}

  defp parse_required_binding_value(nil), do: nil
  defp parse_required_binding_value(value), do: parse_binding_value(value)

  defp parse_optional_binding_value(nil), do: nil
  defp parse_optional_binding_value(value), do: parse_binding_value(value)

  defp parse_binding_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse_binding_value(value), do: value

  defp parse_allowed_chat_ids(nil), do: {:ok, []}

  defp parse_allowed_chat_ids(value) when is_binary(value) do
    value
    |> String.split([",", "\n", " "], trim: true)
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Integer.parse(raw) do
        {integer, ""} -> {:cont, {:ok, [integer | acc]}}
        _ -> {:halt, {:error, :invalid_allowed_chat_ids}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_gateway_bindings(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, fn line, {kept, dropping?} ->
      cond do
        gateway_binding_header?(line) ->
          {kept, true}

        dropping? and table_header?(line) ->
          {[line | kept], false}

        dropping? ->
          {kept, true}

        true ->
          {[line | kept], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp append_gateway_bindings(content, []), do: ensure_final_newline(content)

  defp append_gateway_bindings(content, bindings) do
    rendered =
      bindings
      |> Enum.map(&render_gateway_binding/1)
      |> Enum.join("\n\n")

    content
    |> ensure_final_newline()
    |> Kernel.<>(if content == "", do: "", else: "\n")
    |> Kernel.<>(rendered)
    |> ensure_final_newline()
  end

  defp render_gateway_binding(binding) do
    [
      "[[gateway.bindings]]",
      binding_line("transport", binding[:transport], :string),
      binding_line("chat_id", binding[:chat_id], :scalar),
      binding_line("topic_id", binding[:topic_id], :scalar),
      binding_line("agent_id", binding[:agent_id], :string),
      binding_line("default_engine", binding[:default_engine], :string),
      binding_line("project", binding[:project], :string)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp binding_line(_key, nil, _type), do: nil
  defp binding_line(_key, "", _type), do: nil
  defp binding_line(key, value, :string), do: raw_string_line(key, value)
  defp binding_line(key, value, :scalar) when is_integer(value), do: "#{key} = #{value}"
  defp binding_line(key, value, :scalar), do: raw_string_line(key, value)

  defp gateway_binding_header?(line),
    do: Regex.match?(~r/^\s*\[\[gateway\.bindings\]\]\s*$/, line)

  defp table_header?(line), do: Regex.match?(~r/^\s*\[+[^]]+\]+\s*$/, line)

  defp ensure_final_newline(""), do: ""

  defp ensure_final_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp normalize_approval_decision(decision) when is_atom(decision) do
    if decision in [:approve_once, :approve_session, :approve_agent, :approve_global, :deny] do
      {:ok, decision}
    else
      {:error, :invalid_decision}
    end
  end

  defp normalize_approval_decision(decision) when is_binary(decision) do
    case decision do
      "approve_once" -> {:ok, :approve_once}
      "once" -> {:ok, :approve_once}
      "approve_session" -> {:ok, :approve_session}
      "session" -> {:ok, :approve_session}
      "approve_agent" -> {:ok, :approve_agent}
      "agent" -> {:ok, :approve_agent}
      "approve_global" -> {:ok, :approve_global}
      "global" -> {:ok, :approve_global}
      "deny" -> {:ok, :deny}
      _ -> {:error, :invalid_decision}
    end
  end

  defp normalize_approval_decision(_), do: {:error, :invalid_decision}

  defp run_summary(run_id, events) do
    started = Enum.find(events, &(&1.event_type == "run_started")) || List.first(events)
    completed = Enum.find(events, &(&1.event_type == "run_completed"))

    %{
      run_id: run_id,
      session_key: value_from_events(events, :session_key),
      agent_id: value_from_events(events, :agent_id),
      engine: value_from_events(events, :engine),
      parent_run_id: value_from_events(events, :parent_run_id),
      started_at_ms: if(started, do: started.ts_ms),
      completed_at_ms: if(completed, do: completed.ts_ms),
      status: run_status(events),
      error: completed && completed.error
    }
  end

  defp run_status(events) do
    completed = Enum.find(events, &(&1.event_type == "run_completed"))

    cond do
      completed && completed.ok? == true ->
        "completed"

      completed &&
          completed.error in [
            :user_requested,
            :interrupted,
            :aborted,
            "user_requested",
            "interrupted",
            "aborted"
          ] ->
        "aborted"

      completed ->
        "error"

      events == [] ->
        "unknown"

      true ->
        "active or incomplete"
    end
  end

  defp event_counts(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      Map.update(acc, event.event_type || "unknown", 1, &(&1 + 1))
    end)
  end

  defp value_from_events(events, field) do
    events
    |> Enum.map(&Map.get(&1, field))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp tool_event?(event) do
    event_type = event.event_type || ""
    is_binary(event.tool) or String.contains?(event_type, "tool")
  end

  defp failure_event?(event) do
    event_type = event.event_type || ""

    event.ok? == false or
      not is_nil(event.error) or
      String.contains?(event_type, "error") or
      String.contains?(event_type, "failed") or
      String.contains?(event_type, "failure")
  end

  defp activity_category(event) do
    haystack =
      [event.event_type, event.tool, event.provenance, event.preview]
      |> Enum.map(&format_activity_value/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(haystack, "cron") or String.contains?(haystack, "heartbeat") ->
        :cron

      String.contains?(haystack, "skill") ->
        :skills

      String.contains?(haystack, "channel") or String.contains?(haystack, "telegram") or
        String.contains?(haystack, "discord") or String.contains?(haystack, "xmtp") or
          String.contains?(haystack, "whatsapp") ->
        :channels

      String.contains?(haystack, "memory") ->
        :memory

      String.contains?(haystack, "log") ->
        :logs

      true ->
        :other
    end
  end

  defp format_activity_value(value) when is_binary(value), do: value
  defp format_activity_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_activity_value(nil), do: ""
  defp format_activity_value(value), do: inspect(value)

  defp format_time_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time_value(value) when is_binary(value), do: value
  defp format_time_value(_), do: nil

  defp child_run_summary(child_run_id, event) do
    payload = get_map(event, :payload, %{})

    %{
      run_id: child_run_id,
      session_key: get_map(event, :session_key),
      agent_id: get_map(event, :agent_id),
      engine: get_map(event, :engine),
      started_at_ms: get_map(event, :ts_ms),
      last_event_at_ms: get_map(event, :ts_ms),
      status: child_status_from_event(event, payload)
    }
  end

  defp merge_child_run(existing, event) do
    payload = get_map(event, :payload, %{})
    ts_ms = get_map(event, :ts_ms)
    status = child_status_from_event(event, payload)

    existing
    |> Map.put(:last_event_at_ms, max_int(existing.last_event_at_ms, ts_ms))
    |> Map.put(:started_at_ms, min_int(existing.started_at_ms, ts_ms))
    |> maybe_put_child_status(status)
  end

  defp maybe_put_child_status(child, "unknown"), do: child
  defp maybe_put_child_status(child, status), do: Map.put(child, :status, status)

  defp build_run_tree(run_id, summaries, children_by_parent, visited) do
    summary = Map.get(summaries, run_id, %{run_id: run_id, status: "unknown"})
    visited = MapSet.put(visited, run_id)

    children =
      children_by_parent
      |> Map.get(run_id, [])
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.map(&build_run_tree(&1, summaries, children_by_parent, visited))

    %{
      run_id: run_id,
      status: summary.status || "unknown",
      engine: summary.engine,
      agent_id: summary.agent_id,
      session_key: summary.session_key,
      started_at_ms: summary.started_at_ms,
      completed_at_ms: summary.completed_at_ms,
      children: children
    }
  end

  defp child_status_from_event(event, payload) do
    event_type = normalize_event_type(get_map(event, :event_type))
    ok = payload_ok?(payload)
    error = payload_error(payload)

    cond do
      event_type == "run_completed" and ok == true ->
        "completed"

      event_type == "run_completed" and
          error in [
            :user_requested,
            :interrupted,
            :aborted,
            "user_requested",
            "interrupted",
            "aborted"
          ] ->
        "aborted"

      event_type == "run_completed" ->
        "error"

      event_type == "run_started" ->
        "started"

      true ->
        "unknown"
    end
  end

  defp min_int(nil, value), do: value
  defp min_int(value, nil), do: value
  defp min_int(a, b) when is_integer(a) and is_integer(b), do: min(a, b)
  defp min_int(a, _), do: a

  defp max_int(nil, value), do: value
  defp max_int(value, nil), do: value
  defp max_int(a, b) when is_integer(a) and is_integer(b), do: max(a, b)
  defp max_int(a, _), do: a

  defp payload_tool(payload) when is_map(payload) do
    get_map(payload, :tool_name) || get_map(payload, :tool) || get_map(payload, :name)
  end

  defp payload_tool(_), do: nil

  defp payload_ok?(payload) when is_map(payload), do: get_map(payload, :ok)
  defp payload_ok?(_), do: nil

  defp payload_error(payload) when is_map(payload) do
    get_map(payload, :error) || get_map(payload, :reason)
  end

  defp payload_error(_), do: nil

  defp payload_preview(payload) when is_map(payload) do
    get_map(payload, :result_preview) ||
      get_map(payload, :preview) ||
      get_map(payload, :message) ||
      get_map(payload, :phase) ||
      payload
  end

  defp payload_preview(payload), do: payload

  defp normalize_event_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_event_type(value) when is_binary(value), do: value
  defp normalize_event_type(nil), do: nil
  defp normalize_event_type(value), do: inspect(value)

  defp get_map(map, key, default \\ nil)
  defp get_map(nil, _key, default), do: default

  defp get_map(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        default
    end
  rescue
    _ -> default
  end

  defp get_map(_map, _key, default), do: default

  defp support_commands do
    %{
      source_dev: "mix lemon.doctor --bundle",
      release_runtime: "bin/lemon_runtime_full eval 'LemonCore.Doctor.CLI.bundle!()'"
    }
  end

  defp planned_panels do
    [
      %{name: "Run detail and failure timeline", status: "partial"},
      %{name: "Cron, skills, channel, memory, and log activity", status: "partial"},
      %{name: "Cron schedule, skill health, and channel config panels", status: "partial"},
      %{name: "Run graph and subagent tree", status: "next"},
      %{name: "Cron mutation controls", status: "next"},
      %{name: "Skills provenance and install/update controls", status: "next"},
      %{name: "Channel transport runtime controls", status: "next"},
      %{name: "Support bundle download", status: "next"}
    ]
  end
end
