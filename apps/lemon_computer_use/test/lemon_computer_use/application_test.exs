defmodule LemonComputerUse.ApplicationTest do
  use ExUnit.Case, async: false

  test "disabled (the default) registers no tools, no prompt section and starts no bridge" do
    refute LemonComputerUse.enabled?()

    refute Enum.any?(LemonAgent.ToolRegistry.all(), fn {name, _, _ownership} ->
             name in [:cua_js, :cua_js_reset]
           end)

    refute Enum.any?(LemonAgent.ContextRegistry.all(), fn {name, _} -> name == :computer_use end)
    assert Supervisor.which_children(LemonComputerUse.Supervisor) == []
    assert LemonComputerUse.status() == %{enabled: false, running: false}
  end

  test "only the resolved LCU provider adds the Chrome surface" do
    connected = [provider: "lcu", lcu_probe: fn -> {:ok, :connected} end]
    unavailable = [provider: "lcu", lcu_probe: fn -> {:error, :disconnected} end]
    local = [provider: "local", probe: fn "local" -> {:ok, :installed} end]

    assert LemonComputerUse.Config.chrome?(connected)
    assert LemonComputerUse.Config.enabled?(connected)
    assert List.last(LemonComputerUse.Config.command(connected)) == "--chrome"
    refute LemonComputerUse.Config.chrome?(unavailable)
    refute "--chrome" in LemonComputerUse.Config.command(unavailable)
    refute LemonComputerUse.Config.chrome?(local)
    refute "--chrome" in LemonComputerUse.Config.command(local)
  end

  test "the config file section is read below the environment" do
    on_exit(fn ->
      System.delete_env("LEMON_COMPUTER_USE_ENABLED")
      LemonCore.Config.reload()
    end)

    dir = LemonCore.Paths.global_config() |> Path.dirname()
    File.mkdir_p!(dir)
    path = LemonCore.Paths.global_config()
    original = File.read(path)

    on_exit(fn ->
      case original do
        {:ok, body} -> File.write!(path, body)
        _ -> File.rm(path)
      end
    end)

    File.write!(path, """
    [runtime.tools.computer_use]
    enabled = true
    declined_origins = ["https://bot.example.ts.net"]
    """)

    LemonCore.Config.reload()

    assert LemonComputerUse.Config.enabled?()
    refute LemonComputerUse.Config.chrome?(provider: "local", probe: fn _ -> {:ok, :ready} end)
    assert "https://bot.example.ts.net" in LemonComputerUse.Config.declined_origins()

    System.put_env("LEMON_COMPUTER_USE_ENABLED", "false")
    refute LemonComputerUse.Config.enabled?()
  end

  test "the environment switch overrides application config" do
    on_exit(fn -> System.delete_env("LEMON_COMPUTER_USE_ENABLED") end)
    System.put_env("LEMON_COMPUTER_USE_ENABLED", "true")
    assert LemonComputerUse.Config.enabled?()
    System.put_env("LEMON_COMPUTER_USE_ENABLED", "off")
    refute LemonComputerUse.Config.enabled?()
  end
end
