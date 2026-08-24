defmodule LemonAutomation.CronPreflightTest do
  # async: false — toggles live in application env and process env.
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronPreflight}

  defmodule ReadyStatus do
    @moduledoc false
    def snapshot(_params) do
      %{
        "count" => 2,
        "readyCount" => 2,
        "routing" => %{"decision" => "ok"}
      }
    end
  end

  defmodule NoCredentialsStatus do
    @moduledoc false
    def snapshot(_params) do
      %{"count" => 3, "readyCount" => 0, "routing" => %{"decision" => "ok"}}
    end
  end

  defmodule NoRouteStatus do
    @moduledoc false
    def snapshot(_params) do
      %{"count" => 3, "readyCount" => 2, "routing" => %{"decision" => "no_ready_provider"}}
    end
  end

  defmodule RaisingStatus do
    @moduledoc false
    def snapshot(_params), do: raise("provider probe exploded")
  end

  # Records the params it was probed with; always ready.
  defmodule EchoStatus do
    @moduledoc false
    def snapshot(params) do
      send(Process.get(:test_pid) || self(), {:probe_params, params})
      %{"count" => 2, "readyCount" => 2, "routing" => %{"decision" => "selected_primary"}}
    end
  end

  # Records the params it was probed with, and only reports a dead route for
  # the global default provider — the pinned route is healthy.
  defmodule RouteScopedStatus do
    @moduledoc false
    def snapshot(params) do
      send(Process.get(:test_pid) || self(), {:probe_params, params})

      case Map.get(params, "provider") do
        nil ->
          %{"count" => 2, "readyCount" => 1, "routing" => %{"decision" => "no_ready_provider"}}

        _ ->
          %{"count" => 2, "readyCount" => 1, "routing" => %{"decision" => "selected_primary"}}
      end
    end
  end

  defmodule RouterUp do
    @moduledoc false
    def available?, do: true
  end

  defmodule RouterDown do
    @moduledoc false
    def available?, do: false
  end

  setup do
    previous_preflight = Application.get_env(:lemon_automation, :cron_preflight)
    previous_drift = Application.get_env(:lemon_automation, :cron_drift_guard)
    previous_model_fun = Application.get_env(:lemon_automation, :cron_default_model_fun)
    previous_preflight_env = System.get_env("LEMON_CRON_PREFLIGHT_ENABLED")
    previous_drift_env = System.get_env("LEMON_CRON_DRIFT_GUARD_ENABLED")

    System.delete_env("LEMON_CRON_PREFLIGHT_ENABLED")
    System.delete_env("LEMON_CRON_DRIFT_GUARD_ENABLED")

    on_exit(fn ->
      restore_app_env(:cron_preflight, previous_preflight)
      restore_app_env(:cron_drift_guard, previous_drift)
      restore_app_env(:cron_default_model_fun, previous_model_fun)
      restore_system_env("LEMON_CRON_PREFLIGHT_ENABLED", previous_preflight_env)
      restore_system_env("LEMON_CRON_DRIFT_GUARD_ENABLED", previous_drift_env)
    end)

    :ok
  end

  describe "check/1 gating" do
    test "command-mode jobs always pass, even when everything else is broken" do
      enable_preflight(status_mod: NoCredentialsStatus, router_mod: RouterDown)
      enable_drift_guard(fn -> {:ok, "model-b"} end)

      job =
        agent_job(%{
          command: "echo hi",
          agent_id: nil,
          session_key: nil,
          prompt: nil,
          captured_default_model: "model-a"
        })

      assert CronPreflight.check(job) == :ok
    end

    test "both guards disabled means anything dispatches" do
      Application.put_env(:lemon_automation, :cron_preflight, enabled: false)
      Application.put_env(:lemon_automation, :cron_drift_guard, enabled: false)

      job = agent_job(%{prompt: nil, session_key: "garbage", captured_default_model: "model-a"})

      assert CronPreflight.check(job) == :ok
    end

    test "an env var override beats app env" do
      Application.put_env(:lemon_automation, :cron_drift_guard, enabled: false)
      Application.put_env(:lemon_automation, :cron_default_model_fun, fn -> {:ok, "model-b"} end)
      System.put_env("LEMON_CRON_DRIFT_GUARD_ENABLED", "true")

      job = agent_job(%{captured_default_model: "model-a"})

      assert {:skip, %{class: :model_drift}} = CronPreflight.drift_check(job)
    end
  end

  describe "drift_check/1" do
    setup do
      enable_drift_guard(fn -> {:ok, "model-b"} end)
      :ok
    end

    test "an explicit model pin passes even when the default changed" do
      job = agent_job(%{model: "model-pinned", captured_default_model: "model-a"})
      assert CronPreflight.drift_check(job) == :ok
    end

    test "a legacy job with no captured model passes" do
      job = agent_job(%{captured_default_model: nil})
      assert CronPreflight.drift_check(job) == :ok
    end

    test "an unchanged default passes" do
      enable_drift_guard(fn -> {:ok, "model-a"} end)
      job = agent_job(%{captured_default_model: "model-a"})
      assert CronPreflight.drift_check(job) == :ok
    end

    test "surrounding whitespace does not count as drift" do
      enable_drift_guard(fn -> {:ok, "  model-a  "} end)
      job = agent_job(%{captured_default_model: "model-a"})
      assert CronPreflight.drift_check(job) == :ok
    end

    test "a changed default fails closed with both values in the detail" do
      job = agent_job(%{captured_default_model: "model-a"})

      assert {:skip, %{class: :model_drift, detail: detail}} = CronPreflight.drift_check(job)
      assert detail =~ "model-a"
      assert detail =~ "model-b"
      assert detail =~ "refresh_captured_model/1"
    end

    test "a removed default fails closed" do
      enable_drift_guard(fn -> {:ok, nil} end)
      job = agent_job(%{captured_default_model: "model-a"})

      assert {:skip, %{class: :model_drift, detail: detail}} = CronPreflight.drift_check(job)
      assert detail =~ "(unset)"
    end

    test "a raising model resolver degrades to :ok instead of skipping" do
      enable_drift_guard(fn -> raise "config loader down" end)
      job = agent_job(%{captured_default_model: "model-a"})

      assert CronPreflight.drift_check(job) == :ok
    end

    test "an :error from the model resolver degrades to :ok" do
      enable_drift_guard(fn -> :error end)
      job = agent_job(%{captured_default_model: "model-a"})

      assert CronPreflight.drift_check(job) == :ok
    end

    test "the guard is skipped entirely when disabled" do
      Application.put_env(:lemon_automation, :cron_drift_guard, enabled: false)
      job = agent_job(%{captured_default_model: "model-a"})

      assert CronPreflight.drift_check(job) == :ok
    end
  end

  describe "readiness_check/1" do
    setup do
      enable_preflight(status_mod: ReadyStatus, router_mod: RouterUp)
      :ok
    end

    test "all-good stubs pass" do
      assert CronPreflight.readiness_check(agent_job(%{})) == :ok
    end

    test "missing target fields report :invalid_target" do
      assert {:skip, %{class: :invalid_target, detail: detail}} =
               CronPreflight.readiness_check(agent_job(%{prompt: "  "}))

      assert detail =~ "prompt"

      assert {:skip, %{class: :invalid_target, detail: detail}} =
               CronPreflight.readiness_check(agent_job(%{agent_id: nil, session_key: nil}))

      assert detail =~ "agent_id"
      assert detail =~ "session_key"
    end

    test "an unroutable session key reports :undeliverable" do
      assert {:skip, %{class: :undeliverable, detail: detail}} =
               CronPreflight.readiness_check(agent_job(%{session_key: "not-a-session-key"}))

      assert detail =~ "not-a-session-key"
    end

    test "channel_peer session keys are routable" do
      key = "agent:agent_pf:telegram:default:group:-100123:thread:7"
      assert CronPreflight.readiness_check(agent_job(%{session_key: key})) == :ok
    end

    test "an unavailable router reports :router_unavailable" do
      enable_preflight(status_mod: ReadyStatus, router_mod: RouterDown)

      assert {:skip, %{class: :router_unavailable}} =
               CronPreflight.readiness_check(agent_job(%{}))
    end

    test "zero credential-ready providers reports :no_ready_provider" do
      enable_preflight(status_mod: NoCredentialsStatus, router_mod: RouterUp)

      assert {:skip, %{class: :no_ready_provider, detail: detail}} =
               CronPreflight.readiness_check(agent_job(%{}))

      assert detail =~ "0 of 3"
    end

    test "a no_ready_provider routing decision reports :no_ready_provider" do
      enable_preflight(status_mod: NoRouteStatus, router_mod: RouterUp)

      assert {:skip, %{class: :no_ready_provider}} = CronPreflight.readiness_check(agent_job(%{}))
    end

    test "the detail distinguishes a dead route from a total credential outage" do
      enable_preflight(status_mod: NoRouteStatus, router_mod: RouterUp)

      assert {:skip, %{class: :no_ready_provider, detail: detail}} =
               CronPreflight.readiness_check(agent_job(%{}))

      # readyCount is 2, so "0 of 3 credential-ready" would be a lie.
      assert detail =~ "no credential-ready provider on the route for this job"
      assert detail =~ "2 of 3"
    end

    test "a pinned job is probed against its own route, not the global default" do
      Process.put(:test_pid, self())
      enable_preflight(status_mod: RouteScopedStatus, router_mod: RouterUp)

      job = agent_job(%{model: "openai-codex:gpt-5-codex"})

      assert CronPreflight.readiness_check(job) == :ok
      assert_received {:probe_params, %{"provider" => "openai-codex", "model" => "gpt-5-codex"}}
    end

    test "an unpinned job still probes the global default route" do
      Process.put(:test_pid, self())
      enable_preflight(status_mod: RouteScopedStatus, router_mod: RouterUp)

      assert {:skip, %{class: :no_ready_provider}} = CronPreflight.readiness_check(agent_job(%{}))
      assert_received {:probe_params, %{}}
    end

    test "a bare model id probes by model only" do
      Process.put(:test_pid, self())
      enable_preflight(status_mod: EchoStatus, router_mod: RouterUp)

      assert CronPreflight.readiness_check(agent_job(%{model: "gpt-5-codex"})) == :ok
      assert_received {:probe_params, params}
      assert params == %{"model" => "gpt-5-codex"}
    end

    test "a raising provider probe degrades to :ok" do
      enable_preflight(status_mod: RaisingStatus, router_mod: RouterUp)

      assert CronPreflight.readiness_check(agent_job(%{})) == :ok
    end

    test "the check is skipped entirely when disabled" do
      Application.put_env(:lemon_automation, :cron_preflight,
        enabled: false,
        status_mod: NoCredentialsStatus,
        router_mod: RouterDown
      )

      assert CronPreflight.readiness_check(agent_job(%{prompt: nil})) == :ok
    end
  end

  describe "format_failure/1" do
    test "renders class and detail" do
      assert CronPreflight.format_failure(%{class: :no_ready_provider, detail: "0 of 3"}) ==
               "preflight:no_ready_provider: 0 of 3"
    end
  end

  defp agent_job(attrs) do
    %CronJob{
      id: "cron_preflight_#{System.unique_integer([:positive, :monotonic])}",
      name: "Preflight Job",
      schedule: "* * * * *",
      agent_id: "agent_pf",
      session_key: "agent:agent_pf:main",
      prompt: "do work"
    }
    |> struct!(attrs)
  end

  defp enable_preflight(opts) do
    Application.put_env(:lemon_automation, :cron_preflight, [enabled: true] ++ opts)
  end

  defp enable_drift_guard(model_fun) do
    Application.put_env(:lemon_automation, :cron_drift_guard, enabled: true)
    Application.put_env(:lemon_automation, :cron_default_model_fun, model_fun)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_app_env(key, value), do: Application.put_env(:lemon_automation, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
