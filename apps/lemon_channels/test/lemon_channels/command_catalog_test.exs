defmodule LemonChannels.CommandCatalogTest do
  use ExUnit.Case, async: true

  alias LemonChannels.CommandCatalog

  @required_commands ~w(/queue /q /steer /reset /reasoning /stop /status /usage /agents /tasks /compress /commands /help /bg /btw)

  test "publishes the Hermes-compatible names with Lemon capability metadata" do
    published_names =
      CommandCatalog.catalog()
      |> Enum.flat_map(fn command -> [command["command"] | command["aliases"]] end)

    assert Enum.all?(@required_commands, &(&1 in published_names))

    Enum.each(@required_commands, fn name ->
      assert {:ok, command} = CommandCatalog.find(name)
      assert is_binary(command["description"])
      assert command["description"] != ""
      assert command["capabilities"] != []
    end)
  end

  test "keeps aliases on one canonical definition" do
    assert {:ok, queue} = CommandCatalog.find("/queue")
    assert {:ok, ^queue} = CommandCatalog.find("/Q add a follow-up")
    assert queue["aliases"] == ["/q"]

    assert {:ok, reset} = CommandCatalog.find("reset")
    assert {:ok, ^reset} = CommandCatalog.find("/new")

    assert {:ok, agents} = CommandCatalog.find("/agents")
    assert {:ok, ^agents} = CommandCatalog.find("/tasks")
  end

  test "documents Lemon-specific cancellation and reasoning semantics" do
    assert {:ok, stop} = CommandCatalog.find("/stop")
    assert stop["capabilities"] == ["conversation.cancel"]
    assert stop["aliases"] == ["/cancel"]
    assert stop["description"] =~ "without a process-wide kill"

    assert {:ok, reasoning} = CommandCatalog.find("/reasoning")
    assert reasoning["capabilities"] == ["session.reasoning"]
    assert reasoning["aliases"] == ["/thinking"]
  end

  test "catalog is deterministic, collision-free, and JSON-safe" do
    commands = CommandCatalog.catalog()

    all_names =
      Enum.flat_map(commands, fn command -> [command["command"] | command["aliases"]] end)

    assert length(all_names) == length(Enum.uniq(all_names))
    assert CommandCatalog.summary()["count"] == length(commands)

    assert CommandCatalog.categories() ==
             Enum.sort_by(CommandCatalog.categories(), & &1["category"])

    assert {:ok, _json} = Jason.encode(commands)
    assert :error = CommandCatalog.find("")
    assert :error = CommandCatalog.find("/unknown")
  end
end
