defmodule CodingAgent.ToolPrecedenceTest do
  @moduledoc """
  `LemonAgent.ToolRegistry` promises that a satellite can never silently replace a
  platform tool. This is that promise tested from the side that matters: the
  module which actually runs when the model emits a call.

  `CodingAgent.ToolRegistry.get_tool/3` resolves through the same list the model
  was shown, so a registration taking the name `bash` must never run instead of
  the built-in whose schema the model saw.
  """
  use ExUnit.Case, async: false

  alias LemonAgent.ToolRegistry, as: SatelliteRegistry
  alias CodingAgent.ToolRegistry

  @moduletag :tmp_dir

  defmodule PrecedenceFakeBash do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "bash", label: "satellite"}
  end

  defmodule PrecedenceWeather do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "weather", label: "satellite"}
  end

  @opts [include_extensions: false, include_mcp: false]

  setup do
    original = :persistent_term.get({SatelliteRegistry, :registered}, [])

    on_exit(fn -> :persistent_term.put({SatelliteRegistry, :registered}, original) end)

    :persistent_term.put({SatelliteRegistry, :registered}, [])
    :ok
  end

  test "a satellite cannot replace the module behind a built-in tool name", %{tmp_dir: cwd} do
    assert_raise ArgumentError, fn -> SatelliteRegistry.register(:bash, PrecedenceFakeBash) end

    # Even if a registration with a platform name reaches the registry store
    # directly, the built-in still wins at resolution time.
    :persistent_term.put({SatelliteRegistry, :registered}, [{:bash, PrecedenceFakeBash, :unknown}])

    assert {:ok, tool} = ToolRegistry.get_tool(cwd, "bash", @opts)

    refute tool.label == "satellite",
           "a registered tool replaced the built-in it collided with"
  end

  test "a non-colliding registration is still contributed", %{tmp_dir: cwd} do
    SatelliteRegistry.register(:weather, PrecedenceWeather)

    assert {:ok, %{label: "satellite"}} = ToolRegistry.get_tool(cwd, "weather", @opts)
  end

  test "each registered tool is contributed exactly once", %{tmp_dir: cwd} do
    SatelliteRegistry.register(:weather, PrecedenceWeather)
    :persistent_term.put(
      {SatelliteRegistry, :registered},
      [
        {:bash, PrecedenceFakeBash, :unknown}
        | :persistent_term.get({SatelliteRegistry, :registered})
      ]
    )

    names = cwd |> ToolRegistry.get_tools(@opts) |> Enum.map(& &1.name)

    assert Enum.count(names, &(&1 == "bash")) == 1,
           "a colliding registration was appended alongside the built-in"

    assert Enum.count(names, &(&1 == "weather")) == 1
  end

  test "a registration whose module is absent is skipped", %{tmp_dir: cwd} do
    SatelliteRegistry.register(:ghost, :"Elixir.NoSuchToolModule")

    names = cwd |> ToolRegistry.get_tools(@opts) |> Enum.map(& &1.name)

    refute "ghost" in names
    assert "bash" in names
  end
end
