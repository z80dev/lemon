defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule ChannelWorker do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{}}
  end

  defmodule ChannelAdapter do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "web-ops-test-channel"

    @impl true
    def meta, do: %{label: "Web Ops Test Channel", capabilities: %{text: true}, docs: nil}

    @impl true
    def child_spec(_opts),
      do: %{id: __MODULE__, start: {LemonWebTest.ChannelWorker, :start_link, [[]]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(_payload), do: {:error, :not_implemented}

    @impl true
    def gateway_methods, do: []
  end

  test "application starts successfully" do
    # The application should be running
    assert Application.started_applications()
           |> Enum.any?(fn {app, _, _} -> app == :lemon_web end)
  end

  test "endpoint configuration exists" do
    config = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    assert is_list(config)
    assert config[:url] || config[:http]
    assert config[:adapter] == Bandit.PhoenixAdapter
  end

  test "router is configured" do
    # The router module should exist and be loadable
    assert Code.ensure_loaded?(LemonWeb.Router)
  end

  test "session live module exists" do
    # The SessionLive module should exist
    assert Code.ensure_loaded?(LemonWeb.SessionLive)
  end

  test "session live ignores coalesced output maps" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}
    message = %{type: :coalesced_output, text: "done", run_id: "run_test"}

    assert {:noreply, ^socket} = LemonWeb.SessionLive.handle_info(message, socket)
  end

  test "static LiveView entrypoint uses vendored Phoenix assets" do
    static_root = Path.expand("../priv/static/assets", __DIR__)
    app_js = File.read!(Path.join(static_root, "app.js"))

    assert app_js =~ ~s|from "/assets/vendor/phoenix.mjs"|
    assert app_js =~ ~s|from "/assets/vendor/phoenix_live_view.esm.js"|
    refute app_js =~ "cdn.jsdelivr.net"
    assert File.exists?(Path.join(static_root, "vendor/phoenix.mjs"))
    assert File.exists?(Path.join(static_root, "vendor/phoenix_live_view.esm.js"))
  end

  test "operations dashboard module exists" do
    assert Code.ensure_loaded?(LemonWeb.OpsDashboardLive)
    assert Code.ensure_loaded?(LemonWeb.OpsRunLive)
    assert Code.ensure_loaded?(LemonWeb.SupportBundleController)
  end

  test "support bundle controller returns a zip download" do
    conn = conn(:get, "/ops/support-bundle")
    conn = LemonWeb.SupportBundleController.download(conn, %{})

    assert conn.status == 200
    assert ["application/zip" <> _] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert conn.resp_body =~ "PK"
  end

  test "operations dashboard snapshot is available" do
    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert is_map(snapshot.runtime)
    assert snapshot.build.lemon_version == "0.1.0"
    assert snapshot.build.runtime_mode in ["source-dev", "release-runtime"]
    assert is_map(snapshot.build.git)
    assert is_map(snapshot.router)
    assert is_map(snapshot.provider)
    assert is_map(snapshot.config.defaults)
    assert is_list(snapshot.config.providers)
    assert is_list(snapshot.provider.checks)
    assert is_list(snapshot.active_sessions)
    assert is_list(snapshot.recent_runs)
    assert is_list(snapshot.pending_approvals)
    assert is_integer(snapshot.activity.total_events)
    assert Enum.any?(snapshot.activity.categories, &(&1.category == "cron"))
    assert is_list(snapshot.cron.jobs)
    assert is_list(snapshot.cron.recent_runs)
    assert is_list(snapshot.skills.checks)
    assert is_list(snapshot.channels.transports)
    assert snapshot.support.source_dev == "mix lemon.doctor --bundle"
  end

  test "operations dashboard exposes cron, skill, and channel support panels" do
    token = System.unique_integer([:positive, :monotonic])
    job_id = "web_ops_cron_#{token}"
    run_id = "web_ops_cron_run_#{token}"
    now = System.system_time(:millisecond)

    :ok =
      LemonCore.Store.put(:cron_jobs, job_id, %{
        id: job_id,
        name: "Web ops cron",
        schedule: "*/15 * * * *",
        enabled: true,
        agent_id: "default",
        session_key: "agent:web:cron",
        timezone: "UTC",
        created_at_ms: now,
        updated_at_ms: now,
        next_run_at_ms: now + 60_000
      })

    :ok =
      LemonCore.Store.put(:cron_runs, run_id, %{
        id: run_id,
        job_id: job_id,
        run_id: "router_run_#{token}",
        status: :failed,
        triggered_by: :manual,
        started_at_ms: now,
        completed_at_ms: now + 100,
        error: "test failure"
      })

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert Enum.any?(snapshot.cron.jobs, &(&1.id == job_id and &1.enabled?))
    assert Enum.any?(snapshot.cron.recent_runs, &(&1.id == run_id and &1.status == "failed"))
    assert snapshot.cron.failed_run_count >= 1
    assert Enum.any?(snapshot.skills.checks, &(&1.name == "skills.directory"))
    assert Enum.any?(snapshot.channels.transports, &(&1.name == "telegram"))

    LemonCore.Store.delete(:cron_jobs, job_id)
    LemonCore.Store.delete(:cron_runs, run_id)
  end

  test "operations dashboard groups support-critical activity from introspection" do
    token = System.unique_integer([:positive, :monotonic])
    now = System.system_time(:millisecond)

    events = [
      {:cron_run_started, %{job_id: "cron_#{token}"}},
      {:skill_loaded, %{skill: "repo-map"}},
      {:channel_message_received, %{channel: "telegram"}},
      {:memory_search_completed, %{query: "setup"}},
      {:log_warning, %{message: "provider retry"}}
    ]

    Enum.with_index(events, fn {event_type, payload}, idx ->
      LemonCore.Introspection.record(event_type, payload,
        run_id: "web_ops_activity_#{token}_#{idx}",
        session_key: "agent:web:activity:#{token}",
        agent_id: "web",
        engine: "echo",
        ts_ms: now + idx
      )
    end)

    categories =
      LemonWeb.OpsDashboard.snapshot().activity.categories
      |> Map.new(&{&1.category, &1.count})

    assert categories["cron"] >= 1
    assert categories["skills"] >= 1
    assert categories["channels"] >= 1
    assert categories["memory"] >= 1
    assert categories["logs"] >= 1
  end

  test "operations run detail summarizes timeline, tools, failures, and children" do
    token = System.unique_integer([:positive, :monotonic])
    run_id = "web_ops_run_#{token}"
    child_run_id = "web_ops_child_#{token}"
    grandchild_run_id = "web_ops_grandchild_#{token}"
    session_key = "agent:web:#{token}"
    now = System.system_time(:millisecond)

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :start},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now
      )

    :ok =
      LemonCore.Introspection.record(:tool_completed, %{tool_name: "bash", result_preview: "ok"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 1
      )

    :ok =
      LemonCore.Introspection.record(:tool_completed, %{tool_name: "grep", error: "missing"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 2
      )

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :child},
        run_id: child_run_id,
        parent_run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 3
      )

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :grandchild},
        run_id: grandchild_run_id,
        parent_run_id: child_run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 4
      )

    detail = LemonWeb.OpsDashboard.run_detail(run_id)

    assert detail.summary.run_id == run_id
    assert detail.summary.status == "active or incomplete"
    assert length(detail.events) == 3
    assert length(detail.tool_events) == 2
    assert [%{tool: "grep"}] = detail.failures
    assert [%{run_id: ^child_run_id, status: "started"}] = detail.children

    assert [%{run_id: ^child_run_id, children: [%{run_id: ^grandchild_run_id}]}] =
             detail.graph.children
  end

  test "operations dashboard exposes and resolves non-expiring approvals" do
    approval_id = "web_ops_approval_#{System.unique_integer([:positive, :monotonic])}"

    LemonCore.ExecApprovalStore.put_pending(approval_id, %{
      id: approval_id,
      run_id: "run_web_ops_approval",
      session_key: "agent:web:approval",
      agent_id: "web",
      tool: "bash",
      action: %{cmd: "echo ok"},
      rationale: "test approval",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert Enum.any?(snapshot.pending_approvals, &(&1.id == approval_id))
    assert :ok = LemonWeb.OpsDashboard.resolve_approval(approval_id, "approve_once")
    refute Enum.any?(LemonWeb.OpsDashboard.snapshot().pending_approvals, &(&1.id == approval_id))
  end

  test "operations dashboard can toggle and run existing cron schedules" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      LemonAutomation.CronManager.add(%{
        name: "web ops controllable cron #{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "web_ops_cron_#{token}",
        session_key: "agent:web_ops_cron_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn -> _ = LemonAutomation.CronManager.remove(job.id) end)

    assert Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.jobs, &(&1.id == job.id))

    assert :ok = LemonWeb.OpsDashboard.set_cron_enabled(job.id, true)

    assert Enum.any?(
             LemonWeb.OpsDashboard.snapshot().cron.jobs,
             &(&1.id == job.id and &1.enabled?)
           )

    assert :ok = LemonWeb.OpsDashboard.run_cron_now(job.id)
    assert Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.recent_runs, &(&1.job_id == job.id))

    assert :ok = LemonWeb.OpsDashboard.set_cron_enabled(job.id, false)

    assert Enum.any?(
             LemonWeb.OpsDashboard.snapshot().cron.jobs,
             &(&1.id == job.id and not &1.enabled?)
           )
  end

  test "operations dashboard can create, edit, and delete cron schedules" do
    token = System.unique_integer([:positive, :monotonic])
    name = "web ops created cron #{token}"

    assert :ok =
             LemonWeb.OpsDashboard.create_cron_job(%{
               "name" => name,
               "schedule" => "0 6 * * *",
               "agent_id" => "web_ops_created_#{token}",
               "session_key" => "agent:web_ops_created_#{token}:main",
               "prompt" => "first prompt",
               "timezone" => "UTC",
               "enabled" => "true"
             })

    job =
      LemonWeb.OpsDashboard.snapshot().cron.jobs
      |> Enum.find(&(&1.name == name))

    assert job.schedule == "0 6 * * *"
    assert job.enabled?

    assert :ok =
             LemonWeb.OpsDashboard.update_cron_job(job.id, %{
               "name" => "#{name} updated",
               "schedule" => "30 7 * * 1",
               "prompt" => "updated prompt",
               "timezone" => "UTC"
             })

    job =
      LemonWeb.OpsDashboard.snapshot().cron.jobs
      |> Enum.find(&(&1.id == job.id))

    assert job.name == "#{name} updated"
    assert job.schedule == "30 7 * * 1"

    assert :ok = LemonWeb.OpsDashboard.delete_cron_job(job.id)

    refute Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.jobs, &(&1.id == job.id))
  end

  test "operations dashboard can install and update skills through installer" do
    token = System.unique_integer([:positive, :monotonic])
    old_agent_dir = System.get_env("LEMON_AGENT_DIR")
    old_approval = Application.fetch_env(:lemon_skills, :require_approval)
    tmp_dir = Path.join(System.tmp_dir!(), "lemon-web-skill-install-#{token}")
    agent_dir = Path.join(tmp_dir, "agent")
    skill_key = "web-install-skill-#{token}"
    source_dir = Path.join(tmp_dir, skill_key)

    System.put_env("LEMON_AGENT_DIR", agent_dir)
    Application.put_env(:lemon_skills, :require_approval, true)
    File.mkdir_p!(source_dir)

    File.write!(
      Path.join(source_dir, "SKILL.md"),
      """
      ---
      name: #{skill_key}
      description: Web install v1
      version: 1.0.0
      ---

      install v1
      """
    )

    on_exit(fn ->
      case old_agent_dir do
        nil -> System.delete_env("LEMON_AGENT_DIR")
        value -> System.put_env("LEMON_AGENT_DIR", value)
      end

      case old_approval do
        {:ok, value} -> Application.put_env(:lemon_skills, :require_approval, value)
        :error -> Application.delete_env(:lemon_skills, :require_approval)
      end

      File.rm_rf(tmp_dir)
      LemonSkills.Registry.refresh()
    end)

    LemonSkills.Registry.refresh()

    assert :ok = LemonWeb.OpsDashboard.install_skill(source_dir, global: true)

    skill =
      LemonWeb.OpsDashboard.snapshot().skills.entries
      |> Enum.find(&(&1.key == skill_key))

    assert skill.description == "Web install v1"
    assert skill.source_kind == "local"
    assert skill.source_id == source_dir

    File.write!(
      Path.join(source_dir, "SKILL.md"),
      """
      ---
      name: #{skill_key}
      description: Web install v2
      version: 1.1.0
      ---

      install v2
      """
    )

    assert :ok = LemonWeb.OpsDashboard.update_skill(skill_key)

    skill =
      LemonWeb.OpsDashboard.snapshot().skills.entries
      |> Enum.find(&(&1.key == skill_key))

    assert skill.description == "Web install v2"
    assert is_binary(skill.updated_at)
  end

  test "operations dashboard exposes skill provenance and can toggle existing skills" do
    token = System.unique_integer([:positive, :monotonic])
    old_agent_dir = System.get_env("LEMON_AGENT_DIR")
    tmp_dir = Path.join(System.tmp_dir!(), "lemon-web-skills-#{token}")
    agent_dir = Path.join(tmp_dir, "agent")
    skill_key = "web-ops-skill-#{token}"
    skill_dir = Path.join([agent_dir, "skill", skill_key])

    System.put_env("LEMON_AGENT_DIR", agent_dir)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: Web Ops Skill #{token}
      description: Web operations skill fixture
      requires:
        bins:
          - definitely-missing-lemon-web-skill-bin-#{token}
      ---

      body
      """
    )

    File.write!(
      Path.join(agent_dir, "skills.lock.json"),
      Jason.encode!(%{
        "version" => 1,
        "skills" => %{
          skill_key => %{
            "key" => skill_key,
            "source_kind" => "local",
            "source_id" => skill_dir,
            "trust_level" => "trusted",
            "audit_status" => "pass",
            "audit_findings" => []
          }
        }
      })
    )

    on_exit(fn ->
      case old_agent_dir do
        nil -> System.delete_env("LEMON_AGENT_DIR")
        value -> System.put_env("LEMON_AGENT_DIR", value)
      end

      File.rm_rf(tmp_dir)
      LemonSkills.Registry.refresh()
    end)

    LemonSkills.Registry.refresh()

    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    assert skill.source_kind == "local"
    assert skill.trust_level == "trusted"
    assert skill.audit_status == "pass"
    assert skill.required_bins == ["definitely-missing-lemon-web-skill-bin-#{token}"]
    assert skill.missing == ["definitely-missing-lemon-web-skill-bin-#{token}"]

    assert :ok = LemonWeb.OpsDashboard.set_skill_enabled(skill_key, false)
    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    refute skill.enabled?
    assert skill.activation_state == "hidden"

    assert :ok = LemonWeb.OpsDashboard.set_skill_enabled(skill_key, true)
    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    assert skill.enabled?
  end

  test "operations dashboard exposes runtime channel status and reconnect controls" do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    old_adapters = Application.get_env(:lemon_channels, :adapters, [])
    Application.put_env(:lemon_channels, :adapters, old_adapters ++ [ChannelAdapter])

    _ = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")

    assert :ok = LemonChannels.Application.register_and_start_adapter(ChannelAdapter)

    on_exit(fn ->
      _ = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")
      Application.put_env(:lemon_channels, :adapters, old_adapters)
    end)

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "running"
    assert channel.connected?
    assert channel.configured?

    assert :ok = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "not_registered"
    assert channel.reconnectable?

    assert :ok = LemonWeb.OpsDashboard.reconnect_channel("web-ops-test-channel")

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "running"
  end

  test "operations dashboard can edit gateway channel enablement config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-channel-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "[gateway]\nenable_telegram = false\n")
    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "telegram"))

    refute channel.enabled?
    assert channel.configurable?
    assert channel.config_key == "enable_telegram"

    assert :ok = LemonWeb.OpsDashboard.set_channel_config_enabled("telegram", true)
    assert File.read!(config_path) =~ "enable_telegram = true"

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "telegram"))

    assert channel.enabled?

    assert :ok = LemonWeb.OpsDashboard.set_channel_config_enabled("telegram", false)
    assert File.read!(config_path) =~ "enable_telegram = false"
  end

  test "operations dashboard can edit channel credentials and bindings config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-channel-binding-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      """
      [gateway]
      enable_telegram = true
      default_engine = "lemon"
      default_cwd = "~/"

      [gateway.telegram]
      bot_token_secret = "old_telegram_secret"
      allowed_chat_ids = [111]
      deny_unbound_chats = false

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 111
      agent_id = "default"
      """
    )

    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_gateway_defaults(%{
               "default_engine" => "codex",
               "default_cwd" => "/tmp/lemon",
               "auto_resume" => "true"
             })

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_telegram_config(%{
               "bot_token_secret" => "telegram_bot_token",
               "allowed_chat_ids" => "111, -100222",
               "deny_unbound_chats" => "true"
             })

    content = File.read!(config_path)
    assert content =~ ~s(default_engine = "codex")
    assert content =~ ~s(default_cwd = "/tmp/lemon")
    assert content =~ "auto_resume = true"
    assert content =~ ~s(bot_token_secret = "telegram_bot_token")
    assert content =~ "allowed_chat_ids = [111, -100222]"
    assert content =~ "deny_unbound_chats = true"

    assert :ok =
             LemonWeb.OpsDashboard.create_channel_binding(%{
               "transport" => "telegram",
               "chat_id" => "-100222",
               "topic_id" => "7",
               "agent_id" => "ops",
               "default_engine" => "codex",
               "project" => "lemon"
             })

    snapshot = LemonWeb.OpsDashboard.snapshot()
    assert snapshot.channels.gateway.default_engine == "codex"
    assert snapshot.channels.telegram.bot_token_secret == "telegram_bot_token"
    assert snapshot.channels.telegram.allowed_chat_ids == [111, -100_222]
    assert snapshot.channels.telegram.deny_unbound_chats?

    created =
      snapshot.channels.bindings
      |> Enum.find(&(&1.chat_id == -100_222))

    assert created.topic_id == 7
    assert created.agent_id == "ops"
    assert created.default_engine == "codex"
    assert created.project == "lemon"

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_binding(created.index, %{
               "transport" => "telegram",
               "chat_id" => "-100333",
               "agent_id" => "updated",
               "default_engine" => "lemon"
             })

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert Enum.any?(
             snapshot.channels.bindings,
             &(&1.chat_id == -100_333 and &1.agent_id == "updated")
           )

    updated = Enum.find(snapshot.channels.bindings, &(&1.chat_id == -100_333))
    assert :ok = LemonWeb.OpsDashboard.delete_channel_binding(updated.index)

    refute Enum.any?(
             LemonWeb.OpsDashboard.snapshot().channels.bindings,
             &(&1.chat_id == -100_333)
           )
  end

  test "operations dashboard can edit defaults and provider reference config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-general-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      """
      [defaults]
      provider = "anthropic"
      model = "claude-sonnet-4-20250514"
      thinking_level = "medium"
      engine = "lemon"

      [providers.anthropic]
      api_key_secret = "old_anthropic_secret"
      """
    )

    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    assert :ok =
             LemonWeb.OpsDashboard.update_default_config(%{
               "provider" => "openai",
               "model" => "gpt-5",
               "thinking_level" => "high",
               "engine" => "codex"
             })

    assert :ok =
             LemonWeb.OpsDashboard.update_provider_config("openai", %{
               "auth_source" => "api_key",
               "api_key_secret" => "llm_openai_api_key",
               "base_url" => "https://api.openai.com/v1"
             })

    content = File.read!(config_path)
    assert content =~ ~s(provider = "openai")
    assert content =~ ~s(model = "gpt-5")
    assert content =~ ~s(thinking_level = "high")
    assert content =~ ~s(engine = "codex")
    assert content =~ "[providers.openai]"
    assert content =~ ~s(auth_source = "api_key")
    assert content =~ ~s(api_key_secret = "llm_openai_api_key")
    assert content =~ ~s(base_url = "https://api.openai.com/v1")
    refute content =~ "sk-"

    {snapshot, provider} =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        snapshot = LemonWeb.OpsDashboard.snapshot()
        provider = Enum.find(snapshot.config.providers, &(&1.id == "openai"))

        if snapshot.config.defaults.provider == "openai" and provider && provider.configured? do
          {:halt, {snapshot, provider}}
        else
          Process.sleep(50)
          {:cont, nil}
        end
      end)

    assert snapshot.config.defaults.provider == "openai"
    assert snapshot.config.defaults.model == "gpt-5"
    assert snapshot.config.defaults.thinking_level == "high"
    assert snapshot.config.defaults.engine == "codex"

    assert provider.configured?
    assert provider.auth_source == "api_key"
    assert provider.api_key_secret == "llm_openai_api_key"
    assert provider.base_url == "https://api.openai.com/v1"
  end
end
