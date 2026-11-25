defmodule LemonControlPlane.Methods.CommandsListTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{CommandsList, Registry}
  alias LemonControlPlane.Protocol.{Frames, Schemas}

  @ctx %{auth: %{role: :operator, scopes: [:read]}}

  setup do
    root = Path.join(System.tmp_dir!(), "commands-list-#{System.unique_integer([:positive])}")
    agent_dir = Path.join(root, "custom-agent")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(workspace, ".lemon/commands"))

    previous = Map.new(~w(LEMON_AGENT_DIR HOME), &{&1, System.get_env(&1)})
    previous_agent_dir = Application.fetch_env(:coding_agent, :agent_dir)
    System.delete_env("LEMON_AGENT_DIR")
    Application.put_env(:coding_agent, :agent_dir, agent_dir)
    System.put_env("HOME", home)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case previous_agent_dir do
        {:ok, value} -> Application.put_env(:coding_agent, :agent_dir, value)
        :error -> Application.delete_env(:coding_agent, :agent_dir)
      end

      File.rm_rf!(root)
    end)

    %{agent_dir: agent_dir, home: home, workspace: workspace}
  end

  test "is a read-scoped, advertised method that requires an absolute cwd" do
    assert CommandsList.name() == "commands.list"
    assert CommandsList.scopes() == [:read]
    assert {:ok, CommandsList} = Registry.lookup("commands.list")

    hello = Jason.decode!(Frames.encode_hello_ok(methods: Registry.list_methods()))
    assert "commands.list" in hello["features"]["methods"]

    assert {:error, _} = Schemas.validate("commands.list", %{})
    assert :ok = Schemas.validate("commands.list", %{"cwd" => "/tmp"})

    assert {:error, {:invalid_request, _}} =
             CommandsList.handle(%{"cwd" => "relative/dir"}, @ctx)
  end

  test "equals the daemon's slash_commands(cwd), including a custom agent_dir",
       %{agent_dir: agent_dir, home: home, workspace: workspace} do
    write(Path.join(agent_dir, "command/deploy.md"), """
    ---
    description: Deploy from the custom agent dir
    argument-hint: [env]
    ---
    Deploy $1
    """)

    # The default agent dir under HOME is not a root when agent_dir is set.
    write(Path.join(home, ".lemon/agent/command/stale.md"), "never listed")
    write(Path.join(workspace, ".lemon/commands/review.md"), "Review $ARGUMENTS")

    assert {:ok, %{"commands" => commands, "truncated" => false}} =
             CommandsList.handle(%{"cwd" => workspace}, @ctx)

    expected =
      workspace
      |> CodingAgent.ControlPlaneProvider.slash_commands()
      |> Enum.map(fn command ->
        %{
          "name" => command.name,
          "description" => command.description,
          "argumentHint" => command.argument_hint
        }
      end)

    assert commands == expected

    assert commands == [
             %{
               "name" => "deploy",
               "description" => "Deploy from the custom agent dir",
               "argumentHint" => "[env]"
             },
             %{"name" => "review", "description" => "", "argumentHint" => nil}
           ]
  end

  test "a deleted command file disappears on the next call", %{workspace: workspace} do
    path = Path.join(workspace, ".lemon/commands/ephemeral.md")
    write(path, "Temporary")

    assert {:ok, %{"commands" => [%{"name" => "ephemeral"}]}} =
             CommandsList.handle(%{"cwd" => workspace}, @ctx)

    File.rm!(path)
    assert {:ok, %{"commands" => []}} = CommandsList.handle(%{"cwd" => workspace}, @ctx)
  end

  defmodule FailingRuntime do
    def slash_commands(_cwd), do: raise("private failure #{System.tmp_dir!()}")
  end

  for {label, runtime} <- [missing: __MODULE__.MissingRuntime, failing: FailingRuntime] do
    test "a #{label} agent runtime is UNAVAILABLE, not an empty list", %{workspace: workspace} do
      previous = Application.get_env(:lemon_core, :agent_runtime_provider)
      Application.put_env(:lemon_core, :agent_runtime_provider, unquote(runtime))

      try do
        assert {:error, {:unavailable, message}} =
                 CommandsList.handle(%{"cwd" => workspace}, @ctx)

        refute message =~ "private failure"
      after
        if previous,
          do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
          else: Application.delete_env(:lemon_core, :agent_runtime_provider)
      end
    end
  end

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
