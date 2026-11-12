defmodule CodingAgent.Session.CodingProfileTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{Session, SettingsManager, SystemPrompt, ToolDisclosure}
  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  defp start_session(root, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          cwd: root,
          workspace_dir: Path.join(root, "workspace"),
          session_key: "agent:default:cli-test",
          model: LemonAgent.Test.Mocks.mock_model(),
          settings_manager: %SettingsManager{tools: %{disclosure: %{profile: "auto"}}},
          extension_inventory: {[], []},
          mcp_tools: []
        ],
        overrides
      )

    start_supervised!(Supervisor.child_spec({Session, opts}, id: make_ref(), restart: :temporary))
  end

  test "cwd coding omits assistant bootstrap and defaults to coding disclosure", %{tmp_dir: root} do
    File.write!(Path.join(root, "AGENTS.md"), "Repository instructions remain authoritative.")
    session = start_session(root)
    state = Session.get_state(session)
    names = Enum.map(state.tools, & &1.name)

    refute state.system_prompt =~ "## Workspace Files (injected)"
    refute state.system_prompt =~ "Assistant Chat Bootstrap"
    refute state.system_prompt =~ "Before doing anything else"
    refute state.system_prompt =~ "embody its persona"
    refute state.system_prompt =~ "<learning-workflow>"
    assert state.system_prompt =~ "Repository instructions remain authoritative."
    assert state.extension_status_report.tool_disclosure.profile == :coding
    assert "read" in names
    assert "edit" in names
    assert "tool_search" in names
    refute "skill_manage" in names
    assert Map.has_key?(state.tool_catalog, "skill_manage")
  end

  test "main assistant chat retains bootstrap and legacy disclosure", %{tmp_dir: root} do
    state = root |> start_session(session_key: "agent:default:main") |> Session.get_state()
    assert state.system_prompt =~ "## Workspace Files (injected)"
    assert state.system_prompt =~ "## SOUL.md"
    assert state.system_prompt =~ "## USER.md"
    assert state.system_prompt =~ "## MEMORY.md"
    assert state.system_prompt =~ "Assistant Chat Bootstrap"
    assert state.extension_status_report.tool_disclosure.profile == :legacy
    assert Enum.any?(state.tools, &(&1.name == "skill_manage"))
  end

  test "task children inherit session mode without widening bootstrap scope", %{tmp_dir: root} do
    for mode <- [:chat, :coding] do
      parent = start_session(root, session_mode: mode)

      for overrides <- [[], [session_mode: :coding]] do
        opts =
          CodingAgent.Tools.Task.Params.build_session_opts(
            root,
            [parent_session: parent, model: LemonAgent.Test.Mocks.mock_model()] ++ overrides,
            %{}
          )

        assert opts[:session_mode] == Keyword.get(overrides, :session_mode, mode)
        assert opts[:session_scope] == :subagent
        assert opts[:task_child]

        child = start_session(root, opts)
        state = Session.get_state(child)
        expected_profile = if opts[:session_mode] == :chat, do: :legacy, else: :coding
        assert state.extension_status_report.tool_disclosure.profile == expected_profile
        refute state.system_prompt =~ "## SOUL.md"
        refute state.system_prompt =~ "## USER.md"
        refute state.system_prompt =~ "## MEMORY.md"
      end
    end
  end

  test "persona and disclosure opt-outs are independent", %{tmp_dir: root} do
    coding = root |> start_session(tool_disclosure: [profile: :legacy]) |> Session.get_state()
    assert coding.extension_status_report.tool_disclosure.profile == :legacy
    refute coding.system_prompt =~ "## Workspace Files (injected)"

    chat =
      root
      |> start_session(session_key: "agent:default:main", persona: false)
      |> Session.get_state()

    refute chat.system_prompt =~ "## Workspace Files (injected)"
    assert chat.extension_status_report.tool_disclosure.profile == :legacy

    with_persona = root |> start_session(persona: true) |> Session.get_state()
    assert with_persona.system_prompt =~ "## SOUL.md"
    assert with_persona.extension_status_report.tool_disclosure.profile == :coding
  end

  test "prompt refresh cannot reintroduce persona", %{tmp_dir: root} do
    parent = self()
    response = LemonAgent.Test.Mocks.assistant_message("done")
    stream = LemonAgent.Test.Mocks.mock_stream_fn_single(response)

    stream_fn = fn model, context, options ->
      send(parent, {:request_prompt, context.system_prompt})
      stream.(model, context, options)
    end

    session = start_session(root, stream_fn: stream_fn)
    File.write!(Path.join(root, "workspace/SOUL.md"), "Persona must not return on refresh")
    :ok = Session.prompt(session, "Inspect the repository")
    assert_receive {:request_prompt, prompt}, 5_000
    refute prompt =~ "Persona must not return on refresh"
    refute prompt =~ "## Workspace Files (injected)"
  end

  test "coding skill metadata stays discoverable without full descriptions", %{tmp_dir: root} do
    skill = Path.join(root, ".lemon/skill/compact-example")
    File.mkdir_p!(skill)
    description = String.duplicate("discoverable ", 30)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: compact-example\ndescription: #{description}\n---\nFull workflow body\n"
    )

    opts = %{
      workspace_dir: Path.join(root, "workspace"),
      contributed_sections: [],
      tool_names: ["read_skill"]
    }

    chat = SystemPrompt.build(root, Map.put(opts, :session_mode, :chat))
    coding = SystemPrompt.build(root, Map.put(opts, :session_mode, :coding))
    assert chat =~ String.trim(description)
    refute coding =~ String.trim(description)
    assert coding =~ "<key>compact-example</key>"
    assert coding =~ "<description>#{String.slice(description, 0, 96)}</description>"
    refute coding =~ "Full workflow body"
  end

  test "mode inference distinguishes local coding from assistant messaging" do
    for key <- [
          nil,
          "agent:default:cli-example",
          "agent:default:tui:local:dm:example",
          "agent:default:acp:local:dm:example"
        ] do
      assert PromptComposer.resolve_session_mode(session_key: key) == :coding
    end

    for key <- ["agent:default:main", "agent:default:telegram:default:dm:123"] do
      assert PromptComposer.resolve_session_mode(session_key: key) == :chat
    end

    assert PromptComposer.resolve_session_mode(
             session_key: "agent:default:main",
             session_mode: "coding"
           ) == :coding

    assert PromptComposer.resolve_session_mode(session_mode: :chat) == :chat
  end

  test "auto profile follows session mode while explicit settings win" do
    settings = %{tools: %{disclosure: %{profile: "auto"}}}
    assert ToolDisclosure.config(settings, nil, :coding).profile == :coding
    assert ToolDisclosure.config(settings, nil, :chat).profile == :legacy
    assert ToolDisclosure.config(%{}, nil, :coding).profile == :coding
    explicit = %{tools: %{disclosure: %{profile: "legacy"}}}
    assert ToolDisclosure.config(explicit, nil, :coding).profile == :legacy
    assert ToolDisclosure.config(settings, [profile: :legacy], :coding).profile == :legacy
  end
end
