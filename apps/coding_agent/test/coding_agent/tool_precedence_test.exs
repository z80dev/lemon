defmodule CodingAgent.ToolPrecedenceTest do
  @moduledoc """
  `LemonAgent.ToolRegistry` promises that a satellite can never silently replace a
  platform tool. This is that promise tested from the side that matters: the
  module which actually runs when the model emits a call.

  `CodingAgent.Tools.all_tools/2` is what `get_tool/3` resolves through, and it
  used to merge registered tools *over* its built-ins — so a registration taking
  the name `bash` would run instead of the built-in whose schema the model had
  been shown.
  """
  use ExUnit.Case, async: false

  alias LemonAgent.ToolRegistry

  defmodule PrecedenceFakeBash do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "bash", label: "satellite"}
  end

  defmodule PrecedenceWeather do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "weather", label: "satellite"}
  end

  setup do
    original = :persistent_term.get({ToolRegistry, :registered}, [])

    on_exit(fn -> :persistent_term.put({ToolRegistry, :registered}, original) end)

    :persistent_term.put({ToolRegistry, :registered}, [])
    :ok
  end

  test "a satellite cannot replace the module behind a built-in tool name" do
    ToolRegistry.register(:bash, PrecedenceFakeBash)

    tool = CodingAgent.Tools.get_tool("bash", File.cwd!())

    assert tool

    refute tool.label == "satellite",
           "a registered tool replaced the built-in it collided with"
  end

  test "a non-colliding registration is still contributed" do
    ToolRegistry.register(:weather, PrecedenceWeather)

    assert CodingAgent.Tools.all_tools(File.cwd!())["weather"].label == "satellite"
  end

  test "coding_tools contributes each registered tool exactly once" do
    ToolRegistry.register(:bash, PrecedenceFakeBash)
    ToolRegistry.register(:weather, PrecedenceWeather)

    names = File.cwd!() |> CodingAgent.Tools.coding_tools() |> Enum.map(& &1.name)

    assert Enum.count(names, &(&1 == "bash")) == 1,
           "a colliding registration was appended alongside the built-in"

    assert Enum.count(names, &(&1 == "weather")) == 1
  end

  test "coding_tools does not raise when a registered module is absent" do
    ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")

    assert is_list(CodingAgent.Tools.coding_tools(File.cwd!()))
  end
end
