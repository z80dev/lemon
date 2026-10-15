defmodule LemonCore.Release.SmokeTest do
  @moduledoc """
  Smoke tests for Lemon runtime releases.

  These tests run in two modes:

  1. **Unit mode** (no tag): validates release configuration and module
     availability without requiring an assembled release binary.

  2. **Smoke mode** (tagged `:smoke`): validates a live running release.
     Requires the release to be running and `LEMON_RUNTIME_SMOKE_PORT` to be
     set. Run from CI after `mix release && <release> daemon`.

  Run the smoke suite:

      LEMON_RUNTIME_SMOKE_PORT=14040 mix test --include smoke
  """

  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Checks.{Config, Runtime}
  alias LemonCore.Doctor.Check
  alias LemonCore.Runtime.{Env, Health, Profile}

  # ──────────────────────────────────────────────────────────────────────────
  # Release configuration unit tests (always run)
  # ──────────────────────────────────────────────────────────────────────────

  describe "release profiles" do
    test "lemon_runtime_min exists and has required apps" do
      profile = Profile.get(:runtime_min)
      assert profile.name == :runtime_min
      assert :lemon_gateway in profile.apps
      assert :lemon_router in profile.apps
      assert :lemon_channels in profile.apps
      assert :lemon_control_plane in profile.apps
    end

    test "lemon_runtime_full is a superset of lemon_runtime_min" do
      min = Profile.get(:runtime_min)
      full = Profile.get(:runtime_full)

      for app <- min.apps do
        assert app in full.apps,
               "Expected #{app} from runtime_min to also be in runtime_full"
      end

      assert length(full.apps) > length(min.apps)
    end
  end

  describe "runtime modules" do
    test "Env resolves valid control and web port boundaries" do
      env = Env.resolve()
      assert env.control_port in 1..65_535
      assert env.web_port in 1..65_535
    end
  end

  describe "doctor checks (unit)" do
    test "Config checks return valid Check structs" do
      checks = Config.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "Runtime checks return valid Check structs" do
      checks = Runtime.run()
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Live release smoke tests (require LEMON_RUNTIME_SMOKE_PORT and :smoke tag)
  # ──────────────────────────────────────────────────────────────────────────

  describe "live release" do
    @describetag :smoke

    setup do
      port_str = System.get_env("LEMON_RUNTIME_SMOKE_PORT")

      if is_nil(port_str) do
        flunk("LEMON_RUNTIME_SMOKE_PORT must be set to run :smoke tests")
      end

      port = String.to_integer(port_str)
      {:ok, port: port}
    end

    test "control-plane healthz returns 200", %{port: port} do
      assert Health.running?(port, timeout_ms: 5_000),
             "Expected control-plane to be healthy on port #{port}"
    end

    test "control-plane responds within 2 seconds", %{port: port} do
      {usec, result} = :timer.tc(fn -> Health.running?(port, timeout_ms: 2_000) end)

      assert result, "healthz did not return 200 on port #{port}"
      assert usec < 2_000_000, "healthz took more than 2 seconds (#{usec}μs)"
    end
  end
end
