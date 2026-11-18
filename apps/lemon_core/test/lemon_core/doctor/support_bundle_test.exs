defmodule LemonCore.Doctor.SupportBundleTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.{Check, Report, SupportBundle}

  # Media, browser and LSP diagnostics belong to other apps and reach the bundle
  # through :doctor_runtime. The bundle's own behaviour — assembling the
  # sections and redacting them — is what lemon_core owns, so the test registers
  # stand-ins rather than requiring those apps to be running.
  defmodule StubMediaJobs do
    def default_dir(project_dir), do: Path.join([project_dir, ".lemon", "media"])

    def default_artifacts_dir(project_dir),
      do: Path.join([project_dir, ".lemon", "media", "artifacts"])

    def summary(_opts) do
      %{
        count: 1,
        status_counts: %{"completed" => 1},
        type_counts: %{"image" => 1},
        cleanup: %{
          embeds_artifact_bytes_in_support_bundle: false,
          includes_raw_paths: false,
          includes_prompts: false,
          includes_provider_responses: false,
          includes_channel_message_bodies: false
        }
      }
    end

    # Shape LemonMedia.MediaJobs.recent/1 returns: already hashed, never the
    # raw prompt. lemon_media owns the test that it hashes.
    def recent(_opts) do
      [%{job_id: "support-media", type: :image, status: :completed, prompt_hash: "sha256:abc123"}]
    end
  end

  defmodule StubMediaSupervisor do
    def status do
      %{supervised: true, running: true, active_jobs: 0, workers: 1, supervisors: 1}
    end
  end

  defmodule StubBrowserServer do
    # Mirrors LemonBrowser.LocalServer.status/0, which is where the endpoint is
    # hashed; that redaction is covered by lemon_browser's own suite.
    def status do
      %{
        available: true,
        running: false,
        pending_requests: 0,
        driver_config: %{
          mode: "remote_cdp",
          attach_only: true,
          launches_browser: false,
          cdp_endpoint_configured: true,
          cdp_endpoint_hash: "sha256:0000000000000000"
        }
      }
    end
  end

  defmodule StubBrowserArtifacts do
    def default_dir(project_dir), do: Path.join([project_dir, ".lemon", "browser"])

    def summary(_opts) do
      %{
        cleanup: %{
          managed: true,
          policy: "managed: 14d or 100 files",
          embeds_artifact_bytes_in_support_bundle: false
        }
      }
    end

    def recent(_opts), do: []
  end

  defmodule StubLspServerManager do
    def status do
      %{
        supervised: true,
        running: true,
        mode: :registry_and_sessions,
        active_servers: [],
        active_count: 0,
        pending_request_count: 0,
        recent_sessions: [],
        registry: %{
          count: 6,
          available_count: 0,
          missing_count: 6,
          cleanup: %{includes_executable_paths: false}
        }
      }
    end
  end

  defmodule StubMemoryProviders do
    # Mirrors LemonMemory.Providers.status/0. lemon_memory is not loaded in an
    # app-scoped lemon_core run, and the redaction this shape encodes is covered
    # by that app's own suite.
    def status do
      %{
        provider_count: 1,
        enabled_provider_count: 1,
        providers: [
          %{
            id: "local",
            enabled: true,
            source: "builtin",
            scopes: ["agent", "all", "session", "workspace"],
            timeout_ms: 2_000,
            module_loaded: true
          }
        ],
        cleanup: %{
          includes_memory_contents: false,
          includes_raw_provider_config: false,
          includes_secret_values: false
        }
      }
    end
  end

  # Channel diagnostics are owned by lemon_channels and reach
  # the bundle through :doctor_runtime like the stubs above. Their vendor
  # content is covered by lemon_channels' own suite; core only proves the
  # bundle carries the probe's output verbatim.
  defmodule StubChannelDiagnostics do
    def status(_opts) do
      %{
        transports: [%{transport: "stub", enabled: true, token_configured: true}],
        registered_transports: ["stub"],
        binding_count: 1,
        unsupported_binding_count: 0,
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_secret_names: false,
          includes_chat_ids: false,
          includes_channel_ids: false,
          includes_guild_ids: false,
          includes_message_bodies: false
        }
      }
    end
  end

  defp register_runtime_stubs do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    # The channel keys are dropped and replaced with stubs so the assertions
    # hold whether or not lemon_channels is registered in this runtime.
    base =
      Keyword.drop(original, [
        :channel_diagnostics,
        :channel_registry
      ])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.merge(base,
        media_jobs: StubMediaJobs,
        media_supervisor: StubMediaSupervisor,
        browser_server: StubBrowserServer,
        browser_artifacts: StubBrowserArtifacts,
        lsp_server_manager: StubLspServerManager,
        memory_providers: StubMemoryProviders,
        channel_diagnostics: StubChannelDiagnostics
      )
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)
  end

  # The bundle reports resolved configuration, so ambient LEMON_* variables from
  # the host (or from tests that ran earlier in the same VM) must not leak in.
  defp isolate_lemon_env do
    names = [
      "LEMON_EXTENSIONS_ENABLED",
      "LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS",
      "LEMON_EXTENSION_PATHS",
      "LEMON_DEFAULT_PROVIDER",
      "LEMON_DEFAULT_MODEL",
      "LEMON_PROVIDER_ROUTING_ENABLED",
      "LEMON_PROVIDER_FALLBACK_PROVIDERS",
      "LEMON_PROVIDER_ROUTING_DEFAULT_POOL",
      "LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE",
      "LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS",
      "LEMON_TERMINAL_BACKENDS_ALLOW",
      "LEMON_TERMINAL_BACKENDS_DENY",
      "LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL",
      "LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES",
      "LEMON_SSH_TERMINAL_ALLOWED_TARGETS"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "writes a zip containing diagnostics and metadata" do
    register_runtime_stubs()
    isolate_lemon_env()
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    previous_paths = Application.get_env(:lemon_core, :paths)
    global_config = Path.join(tmp_dir, "global.toml")
    Application.put_env(:lemon_core, :paths, global_config: global_config)
    LemonCore.ConfigCache.clear()

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      LemonCore.ConfigCache.clear()
    end)

    endpoint = "ws://user:secret@example.invalid:9222/devtools/browser/private"
    previous_endpoint = System.get_env("LEMON_BROWSER_CDP_ENDPOINT")
    System.put_env("LEMON_BROWSER_CDP_ENDPOINT", endpoint)

    on_exit(fn ->
      if previous_endpoint do
        System.put_env("LEMON_BROWSER_CDP_ENDPOINT", previous_endpoint)
      else
        System.delete_env("LEMON_BROWSER_CDP_ENDPOINT")
      end
    end)

    File.write!(
      global_config,
      """
      [providers.openai]
      api_key = "sk-test-inline-secret"
      api_key_secret = "llm_openai_secret_name"
      base_url = "https://example.invalid/v1"

      [providers.anthropic]
      oauth_secret = "llm_anthropic_oauth_secret_name"
      auth_source = "oauth"

      [defaults]
      provider = "openai"
      model = "openai:test-model"

      [runtime]
      extension_paths = ["custom_extensions"]

      [runtime.provider_routing]
      fallback_providers = ["anthropic"]
      default_pool = "primary"

      [runtime.provider_routing.credential_pools.primary]
      providers = ["openai", "anthropic"]
      strategy = "priority"

      [gateway]
      max_concurrent_runs = 2
      auto_resume = true
      """
    )

    project_extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    custom_extension_dir = Path.join(tmp_dir, "custom_extensions")
    File.mkdir_p!(project_extension_dir)
    File.mkdir_p!(custom_extension_dir)

    File.write!(
      Path.join(project_extension_dir, "project_extension.exs"),
      "defmodule ProjectExt do end\n"
    )

    File.write!(
      Path.join(custom_extension_dir, "custom_extension.ex"),
      "defmodule CustomExt do end\n"
    )

    File.write!(
      Path.join(custom_extension_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "private-plugin-name",
        version: "0.1.0",
        capabilities: ["tools", "memory_provider"],
        providers: [
          %{
            type: "memory",
            name: "private-memory-provider",
            endpoint: "https://secret.example.invalid/memory"
          }
        ],
        hosts: [%{type: "beam"}, %{type: "wasm"}, %{type: "mcp"}],
        distribution: %{
          source: "git",
          url: "https://token@example.invalid/private/plugin.git"
        },
        audit: %{status: "pending"}
      })
    )

    bundle_path = Path.join(tmp_dir, "support.zip")
    report = Report.from_checks([Check.pass("runtime.boot", "ok")])
    today_key = Date.to_iso8601(Date.utc_today())
    previous_usage_summary = LemonCore.UsageStore.get_summary(:current)
    previous_today_usage = LemonCore.UsageStore.get_record(today_key)
    cron_token = System.unique_integer([:positive, :monotonic])
    cron_job_id = "cron_support_job_#{cron_token}"
    cron_run_id = "cron_support_run_#{cron_token}"
    cron_prompt = "private scheduled support prompt #{cron_token}"
    cron_output = "private scheduled support output #{cron_token}"
    cron_error = "private scheduled support error #{cron_token}"
    cron_session_key = "agent:support-cron-#{cron_token}:main"
    cron_memory_file = "/private/support-cron-memory-#{cron_token}.md"

    on_exit(fn ->
      LemonCore.Store.delete(:cron_jobs, cron_job_id)
      LemonCore.Store.delete(:cron_runs, cron_run_id)

      if previous_usage_summary do
        LemonCore.UsageStore.put_summary(:current, previous_usage_summary)
      else
        LemonCore.Store.delete(:usage_data, :current)
      end

      if previous_today_usage do
        LemonCore.UsageStore.put_record(today_key, previous_today_usage)
      else
        LemonCore.Store.delete(:usage_records, today_key)
      end
    end)

    LemonCore.Store.put(:cron_jobs, cron_job_id, %{
      id: cron_job_id,
      name: "private support cron #{cron_token}",
      schedule: "*/10 * * * *",
      enabled: true,
      agent_id: "support-cron-agent-#{cron_token}",
      session_key: cron_session_key,
      prompt: cron_prompt,
      memory_file: cron_memory_file,
      timezone: "UTC",
      jitter_sec: 5,
      timeout_ms: 60_000,
      created_at_ms: 1_000,
      updated_at_ms: 2_000,
      last_run_at_ms: 3_000,
      next_run_at_ms: 4_000,
      meta: %{private_key: "private support meta"}
    })

    LemonCore.Store.put(:cron_runs, cron_run_id, %{
      id: cron_run_id,
      job_id: cron_job_id,
      run_id: "router_#{cron_run_id}",
      status: :failed,
      started_at_ms: 5_000,
      completed_at_ms: 6_000,
      duration_ms: 1_000,
      triggered_by: :manual,
      output: cron_output,
      error: cron_error,
      suppressed: false,
      meta: %{agent_id: "support-cron-agent-#{cron_token}", session_key: cron_session_key}
    })

    LemonCore.UsageStore.put_summary(:current, %{
      total_cost: 0.42,
      total_requests: 3,
      total_tokens: %{input: 1_000, output: 500},
      breakdown: %{"openai" => 0.42},
      requests: %{"openai" => 3},
      tokens: %{"openai" => %{input: 1_000, output: 500}},
      prompt: "private usage prompt",
      response: "private usage response",
      api_key: "usage-secret-key"
    })

    LemonCore.UsageStore.put_record(today_key, %{
      date: today_key,
      total_cost: 0.42,
      requests: %{"openai" => 3},
      message_body: "private usage message body"
    })

    assert {:ok, ^bundle_path} =
             SupportBundle.write(report, bundle_path: bundle_path, project_dir: tmp_dir)

    assert File.exists?(bundle_path)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
    names = Enum.map(entries, fn {name, _content} -> List.to_string(name) end)

    assert "README.txt" in names
    assert "manifest.json" in names
    assert "doctor_report.json" in names
    assert "environment.json" in names
    assert "browser_diagnostics.json" in names
    assert "channel_diagnostics.json" in names
    assert "checkpoint_diagnostics.json" in names
    assert "cron_diagnostics.json" in names
    assert "extension_diagnostics.json" in names
    assert "goal_diagnostics.json" in names
    assert "kanban_diagnostics.json" in names
    assert "lsp_diagnostics.json" in names
    assert "media_diagnostics.json" in names
    assert "memory_diagnostics.json" in names
    assert "provider_diagnostics.json" in names
    assert "terminal_diagnostics.json" in names
    assert "usage_diagnostics.json" in names
    assert "config/global_config.toml" in names
    assert "config/project_config.toml" in names

    {_, readme_text} = Enum.find(entries, fn {name, _content} -> name == ~c"README.txt" end)
    readme = IO.iodata_to_binary(readme_text)
    assert readme =~ "chat/channel/guild ids"

    {_, manifest_json} = Enum.find(entries, fn {name, _content} -> name == ~c"manifest.json" end)
    manifest = manifest_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert manifest["runtime_mode"] in ["source-dev", "release-runtime"]
    assert is_map(manifest["git"])
    assert is_binary(manifest["elixir"])
    assert is_binary(manifest["otp"])

    {_, browser_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"browser_diagnostics.json" end)

    browser_text = IO.iodata_to_binary(browser_json)
    browser = Jason.decode!(browser_text)

    assert is_map(browser["local_server"])
    assert browser["local_server"]["driver_config"]["mode"] == "remote_cdp"
    assert browser["local_server"]["driver_config"]["attach_only"] == true
    assert browser["local_server"]["driver_config"]["launches_browser"] == false
    assert browser["local_server"]["driver_config"]["cdp_endpoint_configured"] == true
    assert is_binary(browser["local_server"]["driver_config"]["cdp_endpoint_hash"])
    refute String.contains?(browser_text, endpoint)
    refute String.contains?(browser_text, "secret")
    assert is_binary(browser["artifacts_dir"])
    assert is_map(browser["artifact_summary"])
    assert browser["artifact_summary"]["cleanup"]["managed"] == true
    assert browser["artifact_summary"]["cleanup"]["policy"] == "managed: 14d or 100 files"

    assert browser["artifact_summary"]["cleanup"]["embeds_artifact_bytes_in_support_bundle"] ==
             false

    assert is_list(browser["recent_artifacts"])

    {_, channel_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"channel_diagnostics.json" end)

    channels = channel_json |> IO.iodata_to_binary() |> Jason.decode!()

    # The channel sections carry the registered stubs' output verbatim. The
    # vendor content those stubs stand in for is covered by lemon_channels'
    # own suite.
    assert channels["transports"] == [
             %{"transport" => "stub", "enabled" => true, "token_configured" => true}
           ]

    assert channels["registered_transports"] == ["stub"]
    assert channels["binding_count"] == 1
    assert channels["unsupported_binding_count"] == 0
    assert channels["cleanup"]["includes_raw_bot_tokens"] == false
    assert channels["cleanup"]["includes_secret_names"] == false
    assert channels["cleanup"]["includes_chat_ids"] == false
    assert channels["cleanup"]["includes_channel_ids"] == false
    assert channels["cleanup"]["includes_guild_ids"] == false
    assert channels["cleanup"]["includes_message_bodies"] == false

    {_, checkpoint_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"checkpoint_diagnostics.json" end)

    checkpoint = checkpoint_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert checkpoint["cleanup"]["embeds_file_contents_in_support_bundle"] == false
    assert checkpoint["cleanup"]["includes_raw_paths"] == false
    assert checkpoint["cleanup"]["includes_raw_session_ids"] == false

    {_, cron_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"cron_diagnostics.json" end)

    cron = cron_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert cron["job_count"] >= 1
    assert cron["enabled_count"] >= 1
    assert cron["run_count"] >= 1
    assert cron["failed_run_count"] >= 1
    assert cron["status_counts"]["failed"] >= 1
    assert cron["trigger_counts"]["manual"] >= 1

    assert Enum.any?(
             cron["recent_jobs"],
             &(&1["prompt_hash"] == short_hash(cron_prompt) and
                 &1["session_key_hash"] == short_hash(cron_session_key) and
                 &1["memory_file_hash"] == short_hash(cron_memory_file))
           )

    assert Enum.any?(
             cron["recent_runs"],
             &(&1["output_hash"] == short_hash(cron_output) and
                 &1["error_hash"] == short_hash(cron_error))
           )

    assert cron["cleanup"]["includes_prompts"] == false
    assert cron["cleanup"]["includes_outputs"] == false
    assert cron["cleanup"]["includes_errors"] == false
    assert cron["cleanup"]["includes_raw_session_ids"] == false
    assert cron["cleanup"]["includes_raw_agent_ids"] == false
    assert cron["cleanup"]["includes_raw_memory_paths"] == false
    assert cron["cleanup"]["includes_meta_values"] == false
    refute inspect(cron) =~ cron_prompt
    refute inspect(cron) =~ cron_output
    refute inspect(cron) =~ cron_error
    refute inspect(cron) =~ cron_session_key
    refute inspect(cron) =~ cron_memory_file
    refute inspect(cron) =~ "private support meta"

    {_, extension_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"extension_diagnostics.json" end)

    extensions = extension_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert extensions["directory_count"] >= 2
    assert extensions["existing_directory_count"] >= 2
    assert extensions["extension_file_count"] >= 2
    assert extensions["manifest_count"] >= 1
    assert extensions["valid_manifest_count"] >= 1
    assert extensions["invalid_manifest_count"] == 0
    assert extensions["configured_extension_path_count"] == 1
    assert extensions["capability_counts"]["tools"] >= 1
    assert extensions["capability_counts"]["memory_provider"] >= 1
    assert extensions["provider_type_counts"]["memory"] >= 1
    assert extensions["host_type_counts"]["beam"] >= 1
    assert extensions["host_type_counts"]["wasm"] >= 1
    assert extensions["host_type_counts"]["mcp"] >= 1
    assert extensions["distribution_source_counts"]["git"] >= 1
    assert extensions["audit_status_counts"]["pending"] >= 1
    assert extensions["execution"]["configured_extension_path_count"] == 1
    assert extensions["execution"]["default_directory_count"] == 2
    assert extensions["execution"]["auto_load_default_paths"] == false
    assert extensions["execution"]["default_directories_diagnostics_only"] == true
    assert extensions["execution"]["diagnostics_loads_extension_code"] == false
    assert extensions["host_runtime"]["hosts"]["beam"]["status"] == "loadable"
    assert extensions["host_runtime"]["hosts"]["beam"]["configured_count"] >= 1
    assert extensions["host_runtime"]["hosts"]["wasm"]["status"] in ["disabled", "configured"]
    assert extensions["host_runtime"]["hosts"]["wasm"]["configured_count"] >= 1
    assert extensions["host_runtime"]["hosts"]["mcp"]["status"] == "manifest_only"
    assert extensions["host_runtime"]["hosts"]["mcp"]["configured_count"] >= 1
    assert extensions["host_runtime"]["degraded_host_count"] == 0
    assert extensions["host_runtime"]["manifest_only_host_count"] >= 1
    assert extensions["host_runtime"]["runtime_health_loads_extension_code"] == false
    assert extensions["cleanup"]["includes_raw_source_paths"] == false
    assert extensions["cleanup"]["includes_file_contents"] == false
    assert extensions["cleanup"]["includes_load_error_messages"] == false
    assert extensions["cleanup"]["includes_manifest_contents"] == false
    assert extensions["cleanup"]["includes_distribution_urls"] == false
    assert extensions["cleanup"]["loads_extension_code"] == false
    assert Enum.all?(extensions["directories"], &is_binary(&1["path_hash"]))
    refute inspect(extensions) =~ project_extension_dir
    refute inspect(extensions) =~ custom_extension_dir
    refute inspect(extensions) =~ "ProjectExt"
    refute inspect(extensions) =~ "CustomExt"
    refute inspect(extensions) =~ "private-plugin-name"
    refute inspect(extensions) =~ "private-memory-provider"
    refute inspect(extensions) =~ "secret.example"
    refute inspect(extensions) =~ "token@example"

    {_, goal_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"goal_diagnostics.json" end)

    goals = goal_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert goals["cleanup"]["includes_objectives"] == false
    assert goals["cleanup"]["includes_raw_session_ids"] == false

    {_, kanban_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"kanban_diagnostics.json" end)

    kanban = kanban_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert kanban["cleanup"]["includes_titles"] == false
    assert kanban["cleanup"]["includes_descriptions"] == false
    assert kanban["cleanup"]["includes_comments"] == false
    assert kanban["cleanup"]["includes_raw_session_ids"] == false

    {_, lsp_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"lsp_diagnostics.json" end)

    lsp = lsp_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert lsp["status"] == "preview"
    assert lsp["supported_language_count"] >= 6
    assert is_list(lsp["supported_languages"])
    assert is_integer(lsp["executable_summary"]["available_count"])
    assert lsp["cleanup"]["includes_raw_paths"] == false
    assert lsp["cleanup"]["includes_file_contents"] == false
    assert lsp["cleanup"]["includes_diagnostics_output"] == false
    assert lsp["cleanup"]["includes_workspace_roots"] == false
    assert lsp["cleanup"]["includes_server_io"] == false
    assert lsp["cleanup"]["includes_raw_session_ids"] == false
    assert lsp["server_manager"]["running"] == true
    assert lsp["server_manager"]["mode"] == "registry_and_sessions"
    assert is_list(lsp["server_manager"]["active_servers"])
    assert is_list(lsp["server_manager"]["recent_sessions"])
    assert lsp["server_manager"]["registry"]["count"] == 6
    assert lsp["server_manager"]["registry"]["cleanup"]["includes_executable_paths"] == false

    {_, media_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"media_diagnostics.json" end)

    media = media_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert is_binary(media["jobs_dir"])
    assert is_binary(media["artifacts_dir"])
    assert media["worker_status"]["supervised"] == true
    assert media["worker_status"]["running"] == true
    assert is_integer(media["worker_status"]["active_jobs"])
    assert media["summary"]["count"] == 1
    assert media["summary"]["status_counts"]["completed"] == 1
    assert media["summary"]["type_counts"]["image"] == 1
    assert media["summary"]["cleanup"]["embeds_artifact_bytes_in_support_bundle"] == false
    assert media["summary"]["cleanup"]["includes_raw_paths"] == false
    assert media["summary"]["cleanup"]["includes_prompts"] == false
    assert media["summary"]["cleanup"]["includes_provider_responses"] == false
    assert media["summary"]["cleanup"]["includes_channel_message_bodies"] == false
    assert [media_job] = media["recent_jobs"]
    assert media_job["job_id"] == "support-media"
    assert media_job["prompt_hash"]
    refute inspect(media) =~ "private prompt"

    {_, memory_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"memory_diagnostics.json" end)

    memory = memory_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert memory["provider_count"] >= 1
    assert memory["enabled_provider_count"] >= 1
    assert Enum.any?(memory["providers"], &(&1["id"] == "local"))
    assert memory["cleanup"]["includes_memory_contents"] == false
    assert memory["cleanup"]["includes_raw_provider_config"] == false
    assert memory["cleanup"]["includes_secret_values"] == false
    refute inspect(memory) =~ "external prompt"
    refute inspect(memory) =~ "private-memory-provider"

    {_, provider_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"provider_diagnostics.json" end)

    provider = provider_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert provider["default_provider"] == "openai"
    assert provider["default_model_configured"] == true
    assert provider["cleanup"]["includes_raw_api_keys"] == false
    assert provider["cleanup"]["includes_secret_names"] == false
    assert provider["cleanup"]["includes_raw_base_urls"] == false
    assert provider["cleanup"]["includes_env_var_names"] == false
    assert provider["cleanup"]["includes_provider_responses"] == false
    assert provider["routing"]["enabled"] == true
    assert provider["routing"]["credential_pool_count"] >= 1

    openai = Enum.find(provider["providers"], &(&1["provider"] == "openai"))
    anthropic = Enum.find(provider["providers"], &(&1["provider"] == "anthropic"))
    assert openai["configured"] == true
    assert openai["credential_ready"] == true
    assert Enum.any?(openai["inline_credentials"], &(&1["field"] == "api_key"))
    assert Enum.any?(openai["endpoint_shape"], &(&1["field"] == "base_url"))

    assert Enum.any?(
             openai["secret_references"],
             &(&1["field"] == "api_key_secret" and &1["configured"] == true)
           )

    assert anthropic["auth_source"] == "oauth"

    assert Enum.any?(
             anthropic["secret_references"],
             &(&1["field"] == "oauth_secret" and &1["configured"] == true)
           )

    provider_text = inspect(provider)
    refute provider_text =~ "sk-test-inline-secret"
    refute provider_text =~ "llm_openai_secret_name"
    refute provider_text =~ "llm_anthropic_oauth_secret_name"
    refute provider_text =~ "https://example.invalid"
    refute provider_text =~ "OPENAI_API_KEY"

    {_, terminal_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"terminal_diagnostics.json" end)

    terminal = terminal_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert terminal["count"] == 4
    assert terminal["default_backend"] == "local"
    assert terminal["policy"]["backend_allowlist_configured"] == false
    assert "local" in terminal["policy"]["allowed_backends"]
    assert terminal["policy"]["approval_required_backends"] == []
    local = Enum.find(terminal["backends"], &(&1["id"] == "local"))
    local_pty = Enum.find(terminal["backends"], &(&1["id"] == "local_pty"))
    docker = Enum.find(terminal["backends"], &(&1["id"] == "docker"))
    ssh = Enum.find(terminal["backends"], &(&1["id"] == "ssh"))
    assert local["id"] == "local"
    assert local["transport"] == "erlang_port"
    assert local_pty["id"] == "local_pty"
    assert local_pty["pty"] == true
    assert docker["id"] == "docker"
    assert docker["transport"] == "docker_cli"
    assert docker["isolation"] == "container"
    assert docker["network"] == "none"
    assert docker["pull_policy"] == "never"
    assert docker["drops_capabilities"] == true
    assert docker["no_new_privileges"] == true
    assert docker["policy"]["allowed"] == true
    assert docker["policy"]["requires_approval"] == false
    assert docker["policy"]["docker"]["pull_policy"] == "never"
    assert ssh["id"] == "ssh"
    assert ssh["transport"] == "openssh_cli"
    assert ssh["configured"] == System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]
    assert ssh["policy"]["ssh"]["allowed_targets_configured"] == false
    refute Map.has_key?(ssh, "target")
    refute inspect(ssh["policy"]) =~ System.get_env("LEMON_SSH_TERMINAL_TARGET", "__unset__")
    assert is_nil(ssh["target_hash"]) or is_binary(ssh["target_hash"])
    assert terminal["cleanup"]["includes_commands"] == false
    assert terminal["cleanup"]["includes_environment"] == false
    assert terminal["cleanup"]["includes_process_output"] == false

    {_, usage_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"usage_diagnostics.json" end)

    usage_text = IO.iodata_to_binary(usage_json)
    usage = Jason.decode!(usage_text)

    assert usage["status"] in ["within_limits", "unlimited"]
    assert usage["period"] == "current"
    assert usage["total_cost"] == 0.42
    assert usage["total_requests"] == 3
    assert usage["total_tokens"]["input"] == 1_000
    assert usage["total_tokens"]["output"] == 500
    assert usage["total_tokens"]["total"] == 1_500
    assert usage["provider_count"] == 1
    assert usage["today"]["date"] == today_key
    assert usage["today"]["cost"] == 0.42
    assert usage["today"]["requests"] == 3

    assert [openai_usage] = usage["providers"]
    assert openai_usage["provider"] == "openai"
    assert openai_usage["cost"] == 0.42
    assert openai_usage["requests"] == 3
    assert openai_usage["input_tokens"] == 1_000
    assert openai_usage["output_tokens"] == 500
    assert usage["cleanup"]["includes_prompts"] == false
    assert usage["cleanup"]["includes_responses"] == false
    assert usage["cleanup"]["includes_message_bodies"] == false
    assert usage["cleanup"]["includes_credentials"] == false
    assert usage["cleanup"]["includes_secret_values"] == false
    refute usage_text =~ "private usage prompt"
    refute usage_text =~ "private usage response"
    refute usage_text =~ "private usage message body"
    refute usage_text =~ "usage-secret-key"
  end

  test "channel diagnostics degrade when no channel runtime is registered" do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.drop(original, [:channel_diagnostics])
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)

    tmp_dir = tmp_dir()
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    report = Report.from_checks([Check.pass("runtime.boot", "ok")])
    bundle_path = Path.join(tmp_dir, "support.zip")

    assert {:ok, ^bundle_path} =
             SupportBundle.write(report, bundle_path: bundle_path, project_dir: tmp_dir)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])

    {_, channel_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"channel_diagnostics.json" end)

    # The probe fallback documented in SupportBundle.channel_diagnostics/1.
    assert channel_json |> IO.iodata_to_binary() |> Jason.decode!() == %{
             "transports" => [],
             "registered_transports" => [],
             "binding_count" => 0,
             "unsupported_binding_count" => 0,
             "cleanup" => %{
               "includes_raw_bot_tokens" => false,
               "includes_secret_names" => false,
               "includes_chat_ids" => false,
               "includes_channel_ids" => false,
               "includes_guild_ids" => false,
               "includes_message_bodies" => false
             }
           }
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_support_bundle_test_#{System.unique_integer([:positive])}"
    )
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
