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
    opts =
      if Enum.any?([:packages_path, :hex], &Keyword.has_key?(opts, &1)),
        do: opts,
        else: Keyword.put_new(opts, :lemon_path, @lemon_path)

    project = Project.new(Path.join(tmp, "my_agent"), opts)

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

  test "preserves contributed tool ownership before invoking constructors", %{tmp: tmp} do
    {project, _} = generate(tmp)
    agent = read(project, "lib/my_agent/agent.ex")

    assert agent =~ "for {_name, module, ownership} <- LemonAgent.ToolRegistry.available(taken)"
    assert agent =~ "LemonAgent.ToolRegistry.build_tool(ownership, fn -> module.tool() end)"
    refute agent =~ "for {_name, module} <-"
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

  describe "with --packages-path" do
    @packages_path "/tmp/unpacked"

    test "points every platform dep at the unpacked packages and overrides", %{tmp: tmp} do
      {project, _} = generate(tmp, packages_path: @packages_path, memory: true)
      mix_exs = read(project, "mix.exs")

      # The unpacked packages declare their siblings as hex requirements, so
      # without override: true Mix would report the path and hex deps diverged.
      for pkg <- ~w(lemon_core lemon_ai lemon_agent lemon_memory) do
        assert mix_exs =~ ~s({:#{pkg}, path: "#{@packages_path}/#{pkg}", override: true})
      end

      refute mix_exs =~ "/apps/"
    end

    test "cannot generate the channel adapter", %{tmp: tmp} do
      assert_raise ArgumentError, ~r/lemon_channels, which is not a published package/, fn ->
        generate(tmp, packages_path: @packages_path, channel: true)
      end
    end

    test "is mutually exclusive with a lemon checkout", %{tmp: tmp} do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        generate(tmp, packages_path: @packages_path, lemon_path: @lemon_path)
      end
    end
  end

  describe "with --hex" do
    test "requires the published packages from Hex, with no paths", %{tmp: tmp} do
      {project, _} = generate(tmp, hex: true)
      mix_exs = read(project, "mix.exs")

      for pkg <- ~w(lemon_core lemon_ai lemon_agent) do
        assert mix_exs =~ ~s({:#{pkg}, "~> 0.2"})
      end

      refute mix_exs =~ "path:"
      refute mix_exs =~ "override"
      refute mix_exs =~ "lemon_channels"
      refute mix_exs =~ "lemon_memory"
    end

    test "--memory adds lemon_memory as a Hex requirement", %{tmp: tmp} do
      {project, _} = generate(tmp, hex: true, memory: true)
      mix_exs = read(project, "mix.exs")

      assert mix_exs =~ ~s({:lemon_memory, "~> 0.2"})
      refute mix_exs =~ "path:"
    end

    test "cannot generate the channel adapter", %{tmp: tmp} do
      assert_raise ArgumentError, ~r/--channel cannot be combined with --hex/, fn ->
        generate(tmp, hex: true, channel: true)
      end

      refute File.exists?(Path.join(tmp, "my_agent"))
    end

    test "is mutually exclusive with a checkout and with unpacked packages", %{tmp: tmp} do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        generate(tmp, hex: true, lemon_path: @lemon_path)
      end

      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        generate(tmp, hex: true, packages_path: "/tmp/unpacked")
      end
    end
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
