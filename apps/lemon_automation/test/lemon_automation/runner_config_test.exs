defmodule LemonAutomation.RunnerConfigTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.RunnerConfig

  setup do
    key = :runner_config_test
    previous = Application.get_env(:lemon_automation, key)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_automation, key)
      else
        Application.put_env(:lemon_automation, key, previous)
      end
    end)

    :ok
  end

  test "normalizes known string keys, preserves atom keys, and applies option precedence" do
    Application.put_env(:lemon_automation, :runner_config_test, %{
      "enabled" => false,
      "interval_hours" => "12",
      "unknown" => :ignored,
      extra: :preserved
    })

    cfg =
      RunnerConfig.config(:runner_config_test, [enabled: true, interval_hours: 6], enabled: true)

    assert cfg[:enabled] == true
    assert cfg[:interval_hours] == "12"
    assert cfg[:extra] == :preserved
    refute Keyword.has_key?(cfg, :unknown)
  end

  test "accepts keyword config and ignores unsupported config shapes" do
    Application.put_env(:lemon_automation, :runner_config_test, enabled: false)
    refute RunnerConfig.config(:runner_config_test, enabled: true)[:enabled]

    Application.put_env(:lemon_automation, :runner_config_test, :invalid)
    assert RunnerConfig.config(:runner_config_test, enabled: true) == [enabled: true]
  end

  test "only literal true enables a runner" do
    assert RunnerConfig.enabled?([])
    assert RunnerConfig.enabled?(enabled: true)

    for value <- [false, nil, "true", 1] do
      refute RunnerConfig.enabled?(enabled: value)
    end
  end

  test "positive integers accept whole strings and otherwise use the default" do
    for value <- [1, 12, "12"] do
      assert RunnerConfig.positive_integer([interval: value], :interval, 6) in [1, 12]
    end

    for value <- [nil, 0, -1, 1.5, "0", "-1", "1.5", "12h", "invalid"] do
      assert RunnerConfig.positive_integer([interval: value], :interval, 6) == 6
    end
  end

  test "idle duration is measured in whole seconds and cannot be negative" do
    assert RunnerConfig.idle_for_seconds(now_ms: 3_999, last_busy_at_ms: 1_000) == 2
    assert RunnerConfig.idle_for_seconds(now_ms: 1_000, last_busy_at_ms: 3_000) == 0
    assert RunnerConfig.idle_for_seconds(now_ms: 1_000) == 0
  end

  test "active sessions and query failures defer background work" do
    assert RunnerConfig.active_sessions?(active_sessions_fun: fn -> [:session] end)
    refute RunnerConfig.active_sessions?(active_sessions_fun: fn -> [] end)
    assert RunnerConfig.active_sessions?(active_sessions_fun: fn -> {:error, :unavailable} end)
    assert RunnerConfig.active_sessions?(active_sessions_fun: fn -> raise "boom" end)
    assert RunnerConfig.active_sessions?(active_sessions_fun: fn -> exit(:boom) end)
    assert RunnerConfig.active_sessions?(active_sessions_mod: nil)
  end
end
