defmodule LemonNew.GeneratorTest do
  use ExUnit.Case, async: true

  alias LemonNew.{Generator, Project}

  @lemon_path "/opt/lemon"

  setup context do
    tmp = Path.join(System.tmp_dir!(), "lemon_new_test_#{:erlang.phash2(context.test)}")
    File.rm_rf!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp generate(tmp, opts \\ []) do
    project =
      Project.new(Path.join(tmp, "my_agent"), Keyword.put_new(opts, :lemon_path, @lemon_path))

    {project, Generator.copy(project)}
  end

  defp read(project, path), do: File.read!(Path.join(project.base_path, path))

  test "generates a project whose files all parse", %{tmp: tmp} do
    {project, created} = generate(tmp)

    assert "mix.exs" in created
    assert "lib/my_agent.ex" in created
    assert "lib/my_agent/agent.ex" in created
    assert "lib/my_agent/tools/word_count.ex" in created
    assert "test/support/fake_llm.ex" in created

    for path <- created, Path.extname(path) in [".ex", ".exs"] do
      contents = read(project, path)

      assert {:ok, _ast} = Code.string_to_quoted(contents),
             "generated #{path} does not parse"
    end
  end

  test "names modules after the application", %{tmp: tmp} do
    {project, _} = generate(tmp)

    assert read(project, "lib/my_agent.ex") =~ "defmodule MyAgent do"
    assert read(project, "lib/my_agent/agent.ex") =~ "defmodule MyAgent.Agent do"
    assert read(project, "mix.exs") =~ "app: :my_agent"
  end

  test "--module overrides the module name only", %{tmp: tmp} do
    {project, _} = generate(tmp, module: "Support.Bot")

    assert read(project, "lib/my_agent.ex") =~ "defmodule Support.Bot do"
    assert read(project, "mix.exs") =~ "app: :my_agent"
  end

  test "points path dependencies at the lemon checkout", %{tmp: tmp} do
    {project, _} = generate(tmp)
    mix_exs = read(project, "mix.exs")

    assert mix_exs =~ ~s({:lemon_core, path: "#{@lemon_path}/apps/lemon_core"})
    assert mix_exs =~ ~s({:lemon_ai, path: "#{@lemon_path}/apps/lemon_ai"})
    assert mix_exs =~ ~s({:lemon_agent, path: "#{@lemon_path}/apps/lemon_agent"})
  end

  test "keeps the eventual hex names alongside the path deps", %{tmp: tmp} do
    {project, _} = generate(tmp)
    mix_exs = read(project, "mix.exs")

    # The two packages whose hex name differs from the application name are the
    # ones most likely to be mistyped, so the generated file spells them out.
    assert mix_exs =~ ~s(# {:lemon_ai, "~> 0.1", hex: :lemon_ai})
    assert mix_exs =~ ~s(# {:lemon_agent, "~> 0.1", hex: :lemon_agent})
  end

  describe "without --channel" do
    test "no channel adapter and no channels dependency", %{tmp: tmp} do
      {project, created} = generate(tmp)

      refute "lib/my_agent/channel.ex" in created
      refute read(project, "mix.exs") =~ "lemon_channels"
      refute read(project, "mix.exs") =~ "lemon_platform_test"
    end
  end

  describe "with --channel" do
    test "generates the adapter, its compliance suite and the dependencies", %{tmp: tmp} do
      {project, created} = generate(tmp, channel: true)

      assert "lib/my_agent/channel.ex" in created
      assert "test/my_agent/channel_test.exs" in created

      mix_exs = read(project, "mix.exs")
      assert mix_exs =~ "lemon_channels"
      assert mix_exs =~ "lemon_platform_test"
      assert mix_exs =~ "only: :test"

      assert read(project, "lib/my_agent/channel.ex") =~ "@behaviour LemonChannels.Plugin"

      assert read(project, "test/my_agent/channel_test.exs") =~
               "use LemonPlatformTest.PluginCase"
    end

    test "the application registers the adapter at boot", %{tmp: tmp} do
      {project, _} = generate(tmp, channel: true)

      assert read(project, "lib/my_agent/application.ex") =~ "MyAgent.Channel.register()"
    end
  end

  describe "with --memory" do
    test "generates the memory module, its tests and the dependency", %{tmp: tmp} do
      {project, created} = generate(tmp, memory: true)

      assert "lib/my_agent/memory.ex" in created
      assert "test/my_agent/memory_test.exs" in created
      assert read(project, "mix.exs") =~ "lemon_memory"
      assert read(project, "config/config.exs") =~ "config :lemon_memory, LemonMemory.Store"
    end
  end

  test "channel and memory compose", %{tmp: tmp} do
    {_project, created} = generate(tmp, channel: true, memory: true)

    assert "lib/my_agent/channel.ex" in created
    assert "lib/my_agent/memory.ex" in created
  end

  test "every template is reachable from some project shape" do
    all = MapSet.new(Generator.template_paths())

    used =
      [[], [channel: true], [memory: true]]
      |> Enum.flat_map(fn opts ->
        Project.new("/tmp/unused", Keyword.put(opts, :lemon_path, @lemon_path))
        |> Generator.files()
        |> Enum.map(&elem(&1, 0))
      end)
      |> MapSet.new()

    assert MapSet.difference(all, used) |> MapSet.to_list() == []
  end
end
