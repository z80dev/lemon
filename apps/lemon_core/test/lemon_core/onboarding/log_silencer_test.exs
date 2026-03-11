defmodule LemonCore.Onboarding.LogSilencerTest do
  use ExUnit.Case, async: false

  alias LemonCore.Onboarding.LogSilencer

  setup do
    primary_level = Map.fetch!(:logger.get_primary_config(), :level)

    handler_level =
      case :logger.get_handler_config(:default) do
        {:ok, %{level: level}} -> level
        _ -> nil
      end

    on_exit(fn ->
      :ok = :logger.set_primary_config(:level, primary_level)

      if handler_level do
        :ok = :logger.set_handler_config(:default, :level, handler_level)
      end
    end)

    %{primary_level: primary_level, handler_level: handler_level}
  end

  test "temporarily raises logger levels and restores them afterward", %{
    primary_level: primary_level,
    handler_level: handler_level
  } do
    LogSilencer.with_quiet_logs(true, fn ->
      assert Map.fetch!(:logger.get_primary_config(), :level) == :emergency

      if handler_level do
        assert {:ok, %{level: :emergency}} = :logger.get_handler_config(:default)
      end
    end)

    assert Map.fetch!(:logger.get_primary_config(), :level) == primary_level

    if handler_level do
      assert {:ok, %{level: ^handler_level}} = :logger.get_handler_config(:default)
    end
  end

  test "nested quiet sections restore only once", %{primary_level: primary_level} do
    LogSilencer.with_quiet_logs(true, fn ->
      outer_level = Map.fetch!(:logger.get_primary_config(), :level)
      assert outer_level == :emergency

      LogSilencer.with_quiet_logs(true, fn ->
        assert Map.fetch!(:logger.get_primary_config(), :level) == :emergency
      end)

      assert Map.fetch!(:logger.get_primary_config(), :level) == :emergency
    end)

    assert Map.fetch!(:logger.get_primary_config(), :level) == primary_level
  end

  test "disabled mode leaves logger unchanged", %{primary_level: primary_level} do
    LogSilencer.with_quiet_logs(false, fn ->
      assert Map.fetch!(:logger.get_primary_config(), :level) == primary_level
    end)
  end
end
