defmodule LemonComputerUse.ApplicationTest do
  use ExUnit.Case, async: false

  test "disabled (the default) registers no tools, no prompt section and starts no bridge" do
    refute LemonComputerUse.enabled?()

    refute Enum.any?(LemonAgent.ToolRegistry.all(), fn {name, _} ->
             name in [:cua_js, :cua_js_reset]
           end)

    refute Enum.any?(LemonAgent.ContextRegistry.all(), fn {name, _} -> name == :computer_use end)
    assert Supervisor.which_children(LemonComputerUse.Supervisor) == []
    assert LemonComputerUse.status() == %{enabled: false, running: false}
  end

  test "the environment switch overrides application config" do
    on_exit(fn -> System.delete_env("LEMON_COMPUTER_USE_ENABLED") end)
    System.put_env("LEMON_COMPUTER_USE_ENABLED", "true")
    assert LemonComputerUse.Config.enabled?()
    System.put_env("LEMON_COMPUTER_USE_ENABLED", "off")
    refute LemonComputerUse.Config.enabled?()
  end
end
