defmodule CodingAgent.SubagentsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Subagents, ToolPolicy}
  alias CodingAgent.Tools.Task.StructuredOutput

  @moduletag :tmp_dir
  @builtin_ids ~w(reviewer scout security-reviewer sonic task-executor)
  @read_tools ~w(read grep find ls agent_message)

  setup %{tmp_dir: tmp_dir} do
    original_home = System.get_env("HOME")
    home = Path.join(tmp_dir, "home")
    cwd = Path.join(tmp_dir, "project")
    global = Path.join([home, ".lemon", "agents"])
    project = Path.join([cwd, ".lemon", "agents"])
    File.mkdir_p!(global)
    File.mkdir_p!(project)
    # Bound the ancestor walk so the enclosing checkout's .omp/.claude dirs are never read.
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home,
        do: System.put_env("HOME", original_home),
        else: System.delete_env("HOME")
    end)

    {:ok, root: tmp_dir, cwd: cwd, home: home, global: global, project: project}
  end

  test "ships read-only reviewers and leaf workers as builtins", %{cwd: cwd} do
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
    assert Enum.all?(Subagents.list(cwd), &(&1.source == :builtin and &1.prompt != ""))

    for id <- ~w(scout reviewer security-reviewer) do
      persona = Subagents.get(cwd, id)
      assert persona.read_only
      assert persona.tools == @read_tools
    end

    refute Subagents.get(cwd, "task-executor").read_only
    sonic = Subagents.get(cwd, "sonic")
    refute sonic.read_only
    assert {sonic.model, sonic.thinking_level} == {"@smol", "low"}
  end

  test "project overrides global, which overrides builtin", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "scout", "description: Global scout", "Global instruction")
    define(global, "global-only", "description: Global custom", "Global custom instruction")

    assert Subagents.get(cwd, "scout").source == :global
    assert Subagents.get(cwd, "scout").prompt == "Global instruction"
    assert Subagents.get(cwd, "global-only").source == :global

    define(project, "scout", "description: Project scout", "Project instruction")
    define(project, "project-only", "description: Project custom", "Project custom instruction")

    assert Subagents.get(cwd, "scout").source == :project
    assert Subagents.get(cwd, "scout").prompt == "Project instruction"
    assert Subagents.get(cwd, "project-only").source == :project

    assert Enum.map(Subagents.list(cwd), & &1.id) ==
             Enum.sort(~w(global-only project-only) ++ @builtin_ids)
  end

  test "reads YAML scalars, lists and body while keeping role separate from identity", context do
    %{cwd: cwd, project: project} = context

    define(
      project,
      "specialist",
      """
      name: specialist
      description: >-
        A focused
        specialist
      model: provider/model-name
      role: coding
      tools:
        - read
        - grep
        - mcp__server__lookup
      read_only: true
      """,
      "  # Instructions\n\nUse exact evidence.\n---\nKeep this body separator.  "
    )

    assert {:ok, persona} = Subagents.fetch(cwd, "specialist")
    assert persona.id == "specialist"
    assert persona.description == "A focused specialist"
    assert persona.model == "provider/model-name"
    assert persona.role == "coding"
    assert persona.tools == ["read", "grep", "mcp__server__lookup"]
    assert persona.read_only

    assert persona.prompt ==
             "# Instructions\n\nUse exact evidence.\n---\nKeep this body separator."
  end

  test "optional fields default and explicit null model, role and tools are accepted", context do
    %{cwd: cwd, project: project} = context
    define(project, "defaults", "description: Defaults")
    define(project, "nulls", "description: Nulls\nmodel: null\nrole: null\ntools: null")

    for id <- ~w(defaults nulls) do
      persona = Subagents.get(cwd, id)
      assert persona.model == nil
      assert persona.role == nil
      assert persona.tools == nil
      assert persona.read_only == false
    end

    define(project, "no-tools", "description: No tools\ntools: []")
    assert Subagents.get(cwd, "no-tools").tools == []
  end

  test "accepts CRLF delimiters and quoted YAML values", %{cwd: cwd, project: project} do
    File.write!(
      Path.join(project, "crlf.md"),
      "---\r\nname: crlf\r\ndescription: 'Review: carefully'\r\n---\r\nInstructions\r\n"
    )

    assert {:ok, persona} = Subagents.fetch(cwd, "crlf")
    assert persona.description == "Review: carefully"
    assert persona.prompt == "Instructions"
  end

  test "invalid project override never exposes global or builtin fallback", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "scout", "description: Valid global")
    File.write!(Path.join(project, "scout.md"), "---\ndescription: [broken\n---\nInstructions")

    assert {:error, error} = Subagents.fetch(cwd, "scout")
    assert error =~ "Invalid project subagent 'scout'"
    assert Subagents.get(cwd, "scout") == nil
    refute Enum.any?(Subagents.list(cwd), &(&1.id == "scout"))
    assert Subagents.get(cwd, "reviewer") != nil
  end

  test "invalid global override shadows builtin but a valid project override wins", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "reviewer", "description: Invalid\nread_only: perhaps")
    assert {:error, error} = Subagents.fetch(cwd, "reviewer")
    assert error =~ "Invalid global subagent"
    assert Subagents.get(cwd, "reviewer") == nil

    define(project, "reviewer", "description: Valid project")
    assert Subagents.get(cwd, "reviewer").source == :project
  end

  test "unreadable matching definitions fail closed", %{cwd: cwd, project: project} do
    File.mkdir_p!(Path.join(project, "scout.md"))
    assert {:error, _} = Subagents.fetch(cwd, "scout")
    assert Subagents.get(cwd, "scout") == nil

    File.ln_s!(Path.join(project, "missing-target"), Path.join(project, "reviewer.md"))
    assert {:error, _} = Subagents.fetch(cwd, "reviewer")
    assert Subagents.get(cwd, "reviewer") == nil
  end

  test "rejects malformed headers, duplicate fields and non-mapping YAML", context do
    %{cwd: cwd, project: project} = context

    for content <- [
          "Instructions without frontmatter",
          "---\ndescription: Unclosed\nInstructions",
          "---\n- description\n---\nInstructions",
          "---\n42\n---\nInstructions",
          "---\ndescription: [broken\n---\nInstructions",
          "---\ndescription: One\ndescription: Two\n---\nInstructions",
          "---\ndescription: Valid\nread_only: true\nread_only: false\n---\nInstructions",
          "---\n---\nInstructions",
          "---\ndescription: Valid\n---",
          "",
          <<255, 254>>
        ] do
      File.write!(Path.join(project, "invalid.md"), content)
      assert {:error, _} = Subagents.fetch(cwd, "invalid"), inspect(content)
      assert Subagents.get(cwd, "invalid") == nil
    end
  end

  test "rejects invalid field types, unknown fields and bounds", context do
    %{cwd: cwd, project: project} = context

    for fields <- [
          "name: another",
          "name: null",
          "description: 42",
          "description: ''",
          "description: #{String.duplicate("d", 1025)}",
          "model: 42",
          "model: ''",
          "model: with spaces",
          "model: #{String.duplicate("m", 257)}",
          "role: []",
          "role: '@coding'",
          "role: #{String.duplicate("r", 65)}",
          "tools: [read, 12]",
          "tools: 12",
          "tools: ['*']",
          "tools: ['bad name']",
          "tools: [#{String.duplicate("t", 129)}]",
          "tools: [#{Enum.map_join(1..129, ",", &"tool_#{&1}")}]",
          "read_only: 'true'",
          "read_only: null",
          "prompt: Not the body",
          "unexpected: value",
          "color: blue",
          "thinking: extreme",
          "thinking: 3",
          "thinkingLevel: low\nthinking-level: high",
          "spawns: [Bad]",
          "spawns: 12",
          "output: 42",
          "output: {ref: shared}",
          "output: {properties: {a: {type: decimal}}}",
          "output: {type: object, properties: {a: {format: date}}}"
        ] do
      header =
        if String.starts_with?(fields, "description:"),
          do: fields,
          else: "description: Valid\n" <> fields

      define(project, "invalid", header)
      assert {:error, _} = Subagents.fetch(cwd, "invalid"), fields
    end

    define(project, "invalid", "description: Valid", String.duplicate("p", 65_537))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "64 KiB"

    define(project, "invalid", "description: Valid\n# " <> String.duplicate("x", 16_384))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "16 KiB"

    File.write!(Path.join(project, "invalid.md"), String.duplicate("x", 131_073))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "128 KiB"
  end

  test "rejects unsafe IDs before path lookup and ignores unsafe filenames", context do
    %{cwd: cwd, project: project} = context

    for id <- [
          nil,
          42,
          "",
          "../scout",
          "/scout",
          "a/b",
          "a\\b",
          ".hidden",
          "@scout",
          "Uppercase",
          "with space",
          "name\n",
          String.duplicate("a", 65)
        ] do
      assert {:error, error} = Subagents.fetch(cwd, id)
      assert error =~ "Invalid subagent ID"
      assert Subagents.get(cwd, id) == nil
    end

    define(project, "Uppercase", "description: Invalid filename")
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
    assert {:error, "Unknown subagent: missing"} = Subagents.fetch(cwd, "missing")
  end

  test "ignores obsolete JSON definitions and non-Markdown files", context do
    %{cwd: cwd, home: home, project: project} = context
    File.mkdir_p!(Path.join([home, ".lemon", "agent"]))
    File.write!(Path.join([cwd, ".lemon", "subagents.json"]), "not valid JSON")
    File.write!(Path.join([home, ".lemon", "agent", "subagents.json"]), "not valid JSON")
    File.write!(Path.join(project, "old.json"), "[]")
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
  end

  test "lists sorted valid definitions and handles missing project directories", context do
    %{cwd: cwd, project: project} = context
    define(project, "aaa", "description: First")
    assert [%{id: "aaa", description: "First"} | _] = Subagents.list(cwd)
    assert Enum.map(Subagents.list(cwd), & &1.id) == Enum.sort(["aaa" | @builtin_ids])
    assert Enum.map(Subagents.list(Path.join(cwd, "missing")), & &1.id) == @builtin_ids
  end

  describe "omp and Claude Code compatibility" do
    test "resolves all seven roots in precedence order", %{cwd: cwd, home: home} do
      roots = [
        {Path.join([cwd, ".lemon", "agents"]), :project},
        {Path.join([cwd, ".omp", "agents"]), :project},
        {Path.join([cwd, ".claude", "agents"]), :project},
        {Path.join([home, ".lemon", "agents"]), :global},
        {Path.join([home, ".omp", "agent", "agents"]), :global},
        {Path.join([home, ".claude", "agents"]), :global}
      ]

      for {dir, _source} <- roots do
        File.mkdir_p!(dir)
        define(dir, "scout", "description: #{dir}")
      end

      for {dir, source} <- roots do
        persona = Subagents.get(cwd, "scout")
        assert {persona.description, persona.source} == {dir, source}
        assert persona.read_only
        File.rm!(Path.join(dir, "scout.md"))
      end

      assert Subagents.get(cwd, "scout").source == :builtin
    end

    test "walks project ancestors nearest first and stops at the git root", %{root: root} do
      repo = Path.join(root, "repo")
      cwd = Path.join([repo, "pkg", "app"])
      File.mkdir_p!(Path.join(repo, ".git"))

      write_agent(Path.join(cwd, ".omp/agents"), "near", "description: Nearest")
      write_agent(Path.join(repo, ".omp/agents"), "near", "description: Repo root")
      write_agent(Path.join(repo, ".omp/agents"), "rooted", "description: Rooted")
      write_agent(Path.join(repo, "pkg/.claude/agents"), "middle", "description: Middle")
      write_agent(Path.join(cwd, ".claude/agents"), "both", "description: Claude")
      write_agent(Path.join(repo, ".omp/agents"), "both", "description: omp")
      write_agent(Path.join(root, ".omp/agents"), "outside", "description: Above root")

      assert Subagents.get(cwd, "near").description == "Nearest"
      assert Subagents.get(cwd, "rooted").source == :project
      assert Subagents.get(cwd, "middle").description == "Middle"
      assert Subagents.get(cwd, "both").description == "omp"
      assert Subagents.get(cwd, "outside") == nil
      assert {:error, "Unknown subagent: outside"} = Subagents.fetch(cwd, "outside")

      assert Enum.map(Subagents.list(cwd), & &1.id) ==
               Enum.sort(~w(both middle near rooted) ++ @builtin_ids)
    end

    test "foreign IDs come from name, falling back to the filename", %{cwd: cwd} do
      dir = Path.join(cwd, ".claude/agents")
      write_agent(dir, "file-name", "name: '  actual-id '\ndescription: Named")
      write_agent(dir, "unnamed", "description: Unnamed")
      write_agent(dir, "bad-name", "name: Bad Name\ndescription: Skipped")

      assert Subagents.get(cwd, "actual-id").description == "Named"
      assert Subagents.get(cwd, "file-name") == nil
      assert Subagents.get(cwd, "unnamed").description == "Unnamed"
      assert Subagents.get(cwd, "bad-name") == nil
      ids = Enum.map(Subagents.list(cwd), & &1.id)
      assert "actual-id" in ids and "unnamed" in ids
      refute "file-name" in ids
    end

    test "parses Claude Code definitions", %{cwd: cwd, home: home} do
      write_agent(Path.join(cwd, ".claude/agents"), "claude-helper", """
      name: claude-helper
      description: Claude style helper
      tools: Read, Grep, Glob, Bash(git:*)
      model: sonnet
      color: blue
      permissionMode: plan
      """)

      write_agent(Path.join(home, ".claude/agents"), "listed", """
      description: Listed models
      model: [inherit, Haiku, "anthropic:claude-sonnet-4-5"]
      tools: [MultiEdit, NotebookEdit, WebFetch, web_search, TodoWrite, TodoRead, LS, yield]
      """)

      assert {:ok, persona} = Subagents.fetch(cwd, "claude-helper")
      assert persona.tools == ~w(read grep find bash)
      assert persona.model == nil
      assert persona.source == :project

      listed = Subagents.get(cwd, "listed")
      assert listed.model == "anthropic:claude-sonnet-4-5"
      assert listed.tools == ~w(edit webfetch websearch todo ls)
      assert listed.source == :global
    end

    test "parses omp definitions and converts JTD output", %{cwd: cwd} do
      write_agent(Path.join(cwd, ".omp/agents"), "omp-helper", """
      name: omp-helper
      description: omp style helper
      tools: [read, task, yield, Write, web_fetch]
      spawns: scout
      model: "@smol"
      thinking-level: medium
      blocking: true
      autoloadSkills: [lint]
      output:
        properties:
          summary: {type: string, metadata: {description: Short summary}}
          files:
            elements: {type: string}
          severity: {enum: [low, high]}
        optionalProperties:
          score: {type: float64, nullable: true}
          counts: {values: {type: uint32}}
          finding:
            discriminator: kind
            mapping:
              bug: {properties: {line: {type: int32}}}
              note: {optionalProperties: {text: {type: timestamp}}}
          extra: {}
      """)

      assert {:ok, persona} = Subagents.fetch(cwd, "omp-helper")
      assert persona.tools == ~w(read task write webfetch)
      assert persona.spawns == ["scout"]
      assert persona.model == "@smol"
      assert persona.thinking_level == "medium"
      refute persona.read_only

      object = fn properties, required ->
        %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => properties,
          "required" => required
        }
      end

      assert persona.output_schema ==
               object.(
                 %{
                   "summary" => %{"type" => "string", "description" => "Short summary"},
                   "files" => %{"type" => "array", "items" => %{"type" => "string"}},
                   "severity" => %{"type" => "string", "enum" => ["low", "high"]},
                   "score" => %{"anyOf" => [%{"type" => "number"}, %{"type" => "null"}]},
                   "counts" => %{
                     "type" => "object",
                     "additionalProperties" => %{"type" => "integer"}
                   },
                   "finding" => %{
                     "oneOf" => [
                       object.(
                         %{"line" => %{"type" => "integer"}, "kind" => %{"const" => "bug"}},
                         ["kind", "line"]
                       ),
                       object.(
                         %{"text" => %{"type" => "string"}, "kind" => %{"const" => "note"}},
                         ["kind"]
                       )
                     ]
                   },
                   "extra" => true
                 },
                 ["files", "severity", "summary"]
               )

      answer = ~s({"summary":"ok","files":[],"severity":"low","finding":{"kind":"bug","line":3}})
      assert {:ok, _} = StructuredOutput.decode(answer, persona.output_schema)
      assert {:error, _} = StructuredOutput.decode(~s({"summary":"ok"}), persona.output_schema)
    end

    test "native definitions accept compat fields strictly", %{cwd: cwd, project: project} do
      define(project, "delegator", "description: D\ntools: 'read, Task'\nthinkingLevel: MAX")
      define(project, "aliases", "description: A\nthinking: high\nthinking_level: High")
      define(project, "spawner", "description: S\nspawns: '*'\nmodel: 'inherit, openai:gpt-5'")
      define(project, "listed", "description: L\nspawns: 'scout, reviewer'\ntools: [Read, read]")

      define(
        project,
        "schema",
        "description: S\noutput: {type: object, properties: {ok: {type: boolean}}, required: [ok]}"
      )

      define(project, "any-output", "description: A\noutput: {}")

      delegator = Subagents.get(cwd, "delegator")
      assert delegator.tools == ["read", "task"]
      assert delegator.spawns == :all
      assert delegator.thinking_level == "xhigh"
      assert Subagents.get(cwd, "aliases").thinking_level == "high"
      assert Subagents.get(cwd, "spawner").spawns == :all
      assert Subagents.get(cwd, "spawner").model == "openai:gpt-5"
      assert Subagents.get(cwd, "listed").spawns == ["scout", "reviewer"]
      assert Subagents.get(cwd, "listed").tools == ["read"]

      assert Subagents.get(cwd, "schema").output_schema == %{
               "type" => "object",
               "properties" => %{"ok" => %{"type" => "boolean"}},
               "required" => ["ok"]
             }

      assert Subagents.get(cwd, "any-output").output_schema == true

      define(project, "invalid", "description: I\nthinking: extreme")
      assert {:error, error} = Subagents.fetch(cwd, "invalid")
      assert error =~ "Invalid project subagent 'invalid': thinking must be one of"
    end

    test "invalid foreign definitions are skipped without shadowing", context do
      %{cwd: cwd, global: global} = context
      define(global, "scout", "description: Global scout")
      write_agent(Path.join(cwd, ".omp/agents"), "scout", "description: 42")
      write_agent(Path.join(cwd, ".claude/agents"), "reviewer", "description: [broken")
      File.write!(Path.join(cwd, ".omp/agents/plain.md"), "no frontmatter")

      assert Subagents.get(cwd, "scout").source == :global
      assert Subagents.get(cwd, "reviewer").source == :builtin
      assert Subagents.get(cwd, "plain") == nil
      assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
    end

    test "foreign definitions tolerate invalid optional fields and long descriptions", context do
      %{cwd: cwd} = context
      description = "a" <> String.duplicate("é", 1500)

      write_agent(Path.join(cwd, ".claude/agents"), "lenient", """
      description: #{description}
      thinking: extreme
      spawns: [Bad]
      output: {ref: shared}
      """)

      persona = Subagents.get(cwd, "lenient")
      assert byte_size(persona.description) == 1023
      assert String.starts_with?(description, persona.description)
      assert persona.thinking_level == nil
      assert persona.spawns == nil
      assert persona.output_schema == nil
    end
  end

  describe "tool_policy/2" do
    test "defaults to leaf worker and normalizes caller maps" do
      assert Subagents.tool_policy(nil, nil) == ToolPolicy.from_profile(:leaf_worker)

      assert Subagents.tool_policy(nil, %{"allow" => ["read"], "no_reply" => true}) ==
               ToolPolicy.from_map(%{"allow" => ["read"], "no_reply" => true})
    end

    test "intersects persona tools and preserves policy restrictions" do
      requested = %{
        "allow" => ["read", "grep", "find", "ls"],
        "deny" => ["grep"],
        "blocked_tools" => ["find"],
        "require_approval" => ["read"],
        "approvals" => %{"read" => "always", "ls" => "never"},
        "no_reply" => true
      }

      policy = Subagents.tool_policy(%{tools: ["read", "grep", "find", "bash"]}, requested)
      assert policy.allow == ["read"]
      assert Map.delete(policy, :allow) == Map.delete(ToolPolicy.from_map(requested), :allow)
      assert ToolPolicy.requires_approval?(policy, "read")
      assert policy.no_reply
      assert Subagents.tool_policy(%{tools: []}, requested).allow == []
    end

    test "read-only identities cannot be relaxed by overrides or caller full access", context do
      %{cwd: cwd, project: project} = context
      broad = ToolPolicy.from_profile(:full_access)

      for id <- ~w(scout reviewer security-reviewer) do
        builtin_policy = Subagents.tool_policy(Subagents.get(cwd, id), broad)
        assert builtin_policy.allow == @read_tools

        define(
          project,
          id,
          "description: Custom\nread_only: false\ntools: [bash, write, read, task]\nspawns: '*'"
        )

        persona = Subagents.get(cwd, id)
        assert persona.read_only
        assert persona.spawns == nil
        assert Subagents.tool_policy(persona, broad).allow == ["read"]
        assert Subagents.tool_policy(%{persona | read_only: false}, broad).allow == ["read"]
      end

      policy = Subagents.tool_policy(%{id: "custom", read_only: true, tools: nil}, broad)
      assert policy.allow == @read_tools

      for tool <- ~w(bash write edit task agent mcp__server__lookup) do
        refute ToolPolicy.allowed?(policy, tool)
      end
    end

    test "readonly still honors caller denies, blocked tools and narrower allow" do
      requested = %{allow: ["read", "grep", "find"], deny: ["grep"], blocked_tools: ["find"]}
      assert Subagents.tool_policy(%{id: "scout"}, requested).allow == ["read"]
    end
  end

  defp define(dir, id, fields, body \\ "Follow the assigned task.") do
    File.write!(Path.join(dir, id <> ".md"), "---\n" <> String.trim(fields) <> "\n---\n" <> body)
  end

  defp write_agent(dir, id, fields) do
    File.mkdir_p!(dir)
    define(dir, id, fields)
  end
end
