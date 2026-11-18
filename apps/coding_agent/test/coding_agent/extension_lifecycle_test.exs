defmodule CodingAgent.ExtensionLifecycleTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Config
  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.ToolPolicy

  @moduletag :tmp_dir

  setup do
    # Keep extension cache isolated between tests.
    CodingAgent.ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()
    :ok
  end

  test "Bot-folder payloads never compile during initialization, reload or rebuild", %{
    tmp_dir: tmp
  } do
    trusted = Path.join(tmp, "trusted")
    bot = Path.join(tmp, "bot")
    File.mkdir_p!(trusted)
    File.mkdir_p!(Path.join(bot, ".lemon/extensions"))
    marker = Path.join(tmp, "compiled")
    payload = Path.join(bot, ".lemon/extensions/payload.exs")
    File.write!(payload, "File.write!(#{inspect(marker)}, \"compiled\")")
    File.ln_s!(payload, Path.join(bot, ".lemon/extensions/symlink.exs"))
    File.ln!(payload, Path.join(bot, ".lemon/extensions/hardlink.exs"))

    opts = [
      cwd: bot,
      config_cwd: trusted,
      settings_manager: %{extension_paths: [], extension_auto_load_default_paths: true},
      tool_opts: [config_cwd: trusted]
    ]

    initial = ExtensionLifecycle.initialize(opts)
    refute File.exists?(marker)
    assert Config.project_extensions_dir(trusted) in initial.extension_paths
    refute Config.project_extensions_dir(bot) in initial.extension_paths

    reloaded = ExtensionLifecycle.reload(opts)
    refute File.exists?(marker)
    assert reloaded.extension_paths == initial.extension_paths

    CodingAgent.ToolRegistry.invalidate_extension_cache()

    ExtensionLifecycle.rebuild_tools(
      opts ++ [extensions: initial.extensions, hooks: initial.hooks]
    )

    refute File.exists?(marker)
  end

  test "session startup keeps Bot instructions and extensions outside the trusted project", %{
    tmp_dir: tmp
  } do
    trusted = Path.join(tmp, "project")
    bot = Path.join(tmp, "bot-session")
    File.mkdir_p!(trusted)
    File.mkdir_p!(Path.join(bot, ".lemon/extensions"))
    File.write!(Path.join(trusted, "AGENTS.md"), "TRUSTED_PROJECT_INSTRUCTIONS")
    File.write!(Path.join(bot, "AGENTS.md"), "BOT_WRITTEN_INSTRUCTIONS")
    marker = Path.join(tmp, "session-compiled")

    File.write!(
      Path.join(bot, ".lemon/extensions/payload.exs"),
      "File.write!(#{inspect(marker)}, \"compiled\")"
    )

    settings = %{
      CodingAgent.SettingsManager.load(trusted)
      | extension_auto_load_default_paths: true
    }

    model = %LemonAi.Types.Model{
      id: "trust-test",
      name: "Trust test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

    session =
      start_supervised!(
        {CodingAgent.Session,
         [cwd: bot, config_cwd: trusted, model: model, settings_manager: settings, tools: []]}
      )

    state = CodingAgent.Session.get_state(session)
    assert state.cwd == bot
    assert state.system_prompt =~ "TRUSTED_PROJECT_INSTRUCTIONS"
    refute state.system_prompt =~ "BOT_WRITTEN_INSTRUCTIONS"
    refute File.exists?(marker)
    assert CodingAgent.Workspace.skill_cwd(bot, config_cwd: trusted) == trusted
  end

  test "stream rules and file commands come from the trusted project, never the Bot folder", %{
    tmp_dir: tmp
  } do
    trusted = Path.join(tmp, "project")
    bot = Path.join(tmp, "bot-session")
    CodingAgent.TestGitRepo.init!(trusted)
    CodingAgent.TestGitRepo.allow_project_stream_rules!(Path.join(tmp, "home"), trusted)

    rule = fn name, pattern, body ->
      "---\nstreamPattern: #{pattern}\ninjectionLimit: 1\n---\n#{body} (#{name})\n"
    end

    files = %{
      Path.join(trusted, ".lemon/rules/trusted.md") =>
        rule.("trusted", "TRUSTED_TOKEN", "TRUSTED_RULE_BODY"),
      Path.join(trusted, ".claude/commands/hello.md") => "TRUSTED_COMMAND $ARGUMENTS",
      Path.join(bot, ".lemon/rules/abot.md") => rule.("abot", "BOT_TOKEN", "BOT_RULE_BODY"),
      Path.join(bot, ".claude/commands/pwn.md") => "BOT_COMMAND_TEMPLATE"
    }

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    parent = self()
    counter = :counters.new(1, [:atomics])

    provider = fn _model, context, _options ->
      :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      text = if call == 1, do: "BOT_TOKEN TRUSTED_TOKEN", else: "fine"

      response = %LemonAi.Types.AssistantMessage{
        role: :assistant,
        content: [%LemonAi.Types.TextContent{type: :text, text: text}],
        stop_reason: :stop,
        api: :mock,
        provider: :mock_provider,
        model: "trust-test"
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      send(parent, {:provider_call, call, inspect(context)})
      :ok = LemonAi.EventStream.push(stream, {:start, %{response | content: []}})
      :ok = LemonAi.EventStream.push(stream, {:text_delta, 0, text})

      if call != 1 do
        :ok = LemonAi.EventStream.push(stream, {:done, :stop, response})
        LemonAi.EventStream.complete(stream, response)
      end

      {:ok, stream}
    end

    model = %LemonAi.Types.Model{
      id: "trust-test",
      name: "Trust test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

    session =
      start_supervised!(
        {CodingAgent.Session,
         [
           cwd: bot,
           config_cwd: trusted,
           model: model,
           stream_fn: provider,
           settings_manager: CodingAgent.SettingsManager.load(trusted),
           tools: []
         ]}
      )

    :ok = CodingAgent.Session.prompt(session, "Answer")
    assert_receive {:provider_call, 1, _initial}, 5_000
    assert_receive {:provider_call, 2, corrected}, 5_000
    assert corrected =~ "TRUSTED_RULE_BODY"
    refute corrected =~ "BOT_RULE_BODY"

    # Control-plane steering expands file commands from config_cwd only.
    CodingAgent.Session.steer(session, "/pwn", origin: :control_plane)
    CodingAgent.Session.steer(session, "/hello steer", origin: :control_plane)
    assert_receive {:provider_call, _, steered}, 5_000
    steered = steered <> inspect(CodingAgent.Session.get_state(session))
    refute steered =~ "BOT_COMMAND_TEMPLATE"
    assert steered =~ "TRUSTED_COMMAND steer"
  end

  describe "extension_paths/2" do
    test "uses explicit settings paths without auto-loading default directories", %{
      tmp_dir: tmp_dir
    } do
      settings_manager = %{extension_paths: ["/tmp/custom/a", "/tmp/custom/b"]}

      assert ExtensionLifecycle.extension_paths(tmp_dir, settings_manager) == [
               "/tmp/custom/a",
               "/tmp/custom/b"
             ]
    end

    test "merges settings paths before trusted global and project paths", %{tmp_dir: tmp_dir} do
      settings_manager = %{
        extension_paths: ["/tmp/custom/a", "/tmp/custom/b"],
        extension_auto_load_default_paths: true
      }

      assert ExtensionLifecycle.extension_paths(tmp_dir, settings_manager) == [
               "/tmp/custom/a",
               "/tmp/custom/b",
               Config.extensions_dir(),
               Config.project_extensions_dir(tmp_dir)
             ]
    end
  end

  describe "initialize/1" do
    test "loads extensions and returns tools/hooks/status", %{tmp_dir: tmp_dir} do
      extension_module =
        create_extension_file(tmp_dir, "InitLifecycle#{System.unique_integer([:positive])}",
          tools: extension_tools_code("ext_lifecycle_tool"),
          hooks: extension_hooks_code()
        )

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: [], extension_auto_load_default_paths: true},
          tool_opts: [],
          tool_policy: ToolPolicy.from_profile(:full_access)
        )

      assert extension_module in result.extensions
      assert Keyword.has_key?(result.hooks, :on_message_start)
      assert is_map(result.extension_status_report)
      assert is_map(result.provider_registration)
      assert is_list(result.extension_paths)

      tool_names = Enum.map(result.tools, & &1.name)
      assert "read" in tool_names
      assert "ext_lifecycle_tool" in tool_names

      cleanup_module(extension_module)
    end

    test "a custom toolset is closed: custom and extra tools only, no extension tools", %{
      tmp_dir: tmp_dir
    } do
      extension_module =
        create_extension_file(tmp_dir, "CustomLifecycle#{System.unique_integer([:positive])}",
          tools: extension_tools_code("ext_custom_tool")
        )

      custom_tool =
        %AgentTool{
          name: "custom_only_tool",
          description: "custom",
          parameters: %{},
          label: "custom",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      extra_tool =
        %AgentTool{
          name: "extra_only_tool",
          description: "extra",
          parameters: %{},
          label: "extra",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: [], extension_auto_load_default_paths: true},
          tool_opts: [],
          tool_policy: ToolPolicy.from_profile(:full_access),
          custom_tools: [custom_tool],
          extra_tools: [extra_tool]
        )

      tool_names = Enum.map(result.tools, & &1.name)
      assert "custom_only_tool" in tool_names
      refute "ext_custom_tool" in tool_names
      assert "extra_only_tool" in tool_names
      refute "read" in tool_names

      cleanup_module(extension_module)
    end
  end

  describe "reload/1" do
    test "reloads extensions and rebuilds tool list with extra tools", %{tmp_dir: tmp_dir} do
      first_module =
        create_extension_file(tmp_dir, "ReloadFirst#{System.unique_integer([:positive])}",
          tools: extension_tools_code("reload_tool_one")
        )

      initial =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: [], extension_auto_load_default_paths: true},
          tool_opts: [],
          tool_policy: ToolPolicy.from_profile(:full_access)
        )

      second_module =
        create_extension_file(tmp_dir, "ReloadSecond#{System.unique_integer([:positive])}",
          tools: extension_tools_code("reload_tool_two")
        )

      extra_tool =
        %AgentTool{
          name: "reload_extra_tool",
          description: "extra",
          parameters: %{},
          label: "extra",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      reloaded =
        ExtensionLifecycle.reload(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: [], extension_auto_load_default_paths: true},
          tool_opts: [],
          tool_policy: ToolPolicy.from_profile(:full_access),
          extra_tools: [extra_tool],
          previous_status_report: initial.extension_status_report
        )

      assert first_module in reloaded.extensions
      assert second_module in reloaded.extensions
      assert is_map(reloaded.provider_registration)
      assert is_map(reloaded.extension_status_report)

      tool_names = Enum.map(reloaded.tools, & &1.name)
      assert "reload_tool_one" in tool_names
      assert "reload_tool_two" in tool_names
      assert "reload_extra_tool" in tool_names

      cleanup_module(first_module)
      cleanup_module(second_module)
    end
  end

  defp extension_tools_code(tool_name) do
    """
    [
      %LemonAgent.Types.AgentTool{
        name: "#{tool_name}",
        description: "tool #{tool_name}",
        parameters: %{},
        label: "#{tool_name}",
        execute: fn _, _, _, _ -> %LemonAgent.Types.AgentToolResult{content: [], details: nil} end
      }
    ]
    """
  end

  defp extension_hooks_code do
    """
    [
      on_message_start: fn _message -> :ok end
    ]
    """
  end

  defp create_extension_file(tmp_dir, module_name, opts) do
    tools = Keyword.get(opts, :tools, "[]")
    hooks = Keyword.get(opts, :hooks, "[]")

    extension_code = """
    defmodule #{module_name} do
      @behaviour CodingAgent.Extensions.Extension

      @impl true
      def name, do: "#{String.downcase(module_name)}"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def tools(_cwd), do: #{tools}

      @impl true
      def hooks, do: #{hooks}
    end
    """

    ext_dir = Path.join(tmp_dir, ".lemon/extensions")
    File.mkdir_p!(ext_dir)
    file_path = Path.join(ext_dir, "#{String.downcase(module_name)}.ex")
    File.write!(file_path, extension_code)

    Module.concat([module_name])
  end

  defp cleanup_module(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
