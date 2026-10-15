defmodule LemonChannels.CommandCatalogTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.SlashCommands
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

  test "/stop and /reasoning expose their capabilities and aliases" do
    assert {:ok, stop} = CommandCatalog.find("/stop")
    assert stop["capabilities"] == ["conversation.cancel"]
    assert stop["aliases"] == ["/cancel"]

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
    assert CommandCatalog.summary()["aliasCount"] == length(all_names) - length(commands)
    assert Enum.sum(Enum.map(CommandCatalog.categories(), & &1["count"])) == length(commands)

    assert CommandCatalog.categories() ==
             Enum.sort_by(CommandCatalog.categories(), & &1["category"])

    assert {:ok, _json} = Jason.encode(commands)
    assert :error = CommandCatalog.find("")
    assert :error = CommandCatalog.find("/unknown")
  end

  test "every Telegram command predicate and portable route has surface metadata" do
    commands = LemonChannels.Adapters.Telegram.Transport.Commands

    native =
      for {function, 2} <- commands.__info__(:functions),
          name = Atom.to_string(function),
          String.ends_with?(name, "_command?"),
          name != "portable_command?",
          do: String.replace_suffix(name, "_command?", "")

    portable = commands.portable_commands() ++ ~w(reset reasoning stop)

    for name <- native ++ portable do
      assert {:ok, command} = CommandCatalog.find(name), "missing Telegram /#{name}"
      assert "telegram" in command["surfaces"]
    end
  end

  test "every registered Discord slash command has surface metadata" do
    for schema <- SlashCommands.slash_commands() do
      assert {:ok, command} = CommandCatalog.find(schema.name), "missing Discord /#{schema.name}"
      assert "discord" in command["surfaces"]
    end

    published =
      CommandCatalog.catalog("discord")
      |> Enum.flat_map(fn command -> [command["command"] | command["aliases"]] end)
      |> Enum.map(&String.trim_leading(&1, "/"))
      |> Enum.sort()

    registered =
      SlashCommands.slash_commands()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert published == registered
  end

  test "help is scoped to accepted commands and aliases" do
    assert {:ok, telegram} =
             LemonChannels.PortableCommand.handle("help", "", %{surface: "telegram"})

    assert telegram =~ "/model"
    assert telegram =~ "/resume"
    assert telegram =~ "/file"
    assert telegram =~ "/new"
    assert telegram =~ "/cancel"
    assert telegram =~ "/remind"
    refute telegram =~ "/lemon"
    refute telegram =~ "/redirect"

    assert {:ok, discord} =
             LemonChannels.PortableCommand.handle("help", "", %{surface: "discord"})

    for name <- ~w(model resume file checkpoint goal session lemon redirect) do
      assert discord =~ "/#{name}"
    end

    refute discord =~ "/remind"
    refute discord =~ "/new"
    refute discord =~ "/compact"
    assert Enum.all?(CommandCatalog.catalog("tui"), &("tui" in &1["surfaces"]))
    assert length(CommandCatalog.catalog("tui")) == 13
    assert length(CommandCatalog.catalog("web")) == 13
  end
end
