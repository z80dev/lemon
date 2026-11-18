defmodule CodingAgent.Tools.BashCommandPolicyTest do
  # Spawns real shells under the session process manager.
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ToolService
  alias CodingAgent.{ToolPolicy, ToolRegistry}
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.ExecutionContext

  @moduletag :tmp_dir

  defp tool(cwd, name, policy) do
    {:ok, tool} =
      ToolRegistry.get_tool(cwd, name,
        tool_policy: policy,
        include_extensions: false,
        include_mcp: false,
        session_id: "command-policy-#{System.unique_integer([:positive])}",
        tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(cwd)
      )

    tool
  end

  defp run(tool, params) do
    case tool.execute.("call-#{System.unique_integer([:positive])}", params, nil, nil) do
      {:ok, %AgentToolResult{} = result} -> result
      %AgentToolResult{} = result -> result
      {:error, _} = error -> error
    end
  end

  defp text(%AgentToolResult{content: content}),
    do: Enum.map_join(content, "", &Map.get(&1, :text, ""))

  defp text({:error, reason}), do: to_string(reason)

  defp refused?(%AgentToolResult{is_error: true} = result),
    do: text(result) =~ "tool policy"

  defp refused?(_result), do: false

  defp victim(cwd) do
    dir = Path.join(cwd, "victim")
    File.mkdir_p!(Path.join(dir, "inner"))
    dir
  end

  test "blocked_commands refuses matching commands before any process starts", %{tmp_dir: cwd} do
    bash = tool(cwd, "bash", ToolPolicy.custom(blocked_commands: ["rm -rf"]))
    dir = victim(cwd)

    for command <- [
          "rm -rf #{dir}",
          "rm  -rf #{dir}",
          "/bin/rm -rf #{dir}",
          "sudo rm -rf #{dir}",
          "true; rm -rf #{dir}",
          "true && rm -rf #{dir}",
          "echo $(rm -rf #{dir})",
          "(cd /tmp && rm -rf #{dir})",
          "bash -c 'rm -rf #{dir}'",
          "\"rm\" '-rf' #{dir}"
        ] do
      result = run(bash, %{"command" => command})
      assert refused?(result), "ran #{command}: #{text(result)}"
      assert text(result) =~ "blocked_commands"
      assert File.dir?(dir), "#{command} removed the directory"
    end

    assert %AgentToolResult{is_error: false} = run(bash, %{"command" => "rm -r #{dir}/inner"})
    refute File.dir?(Path.join(dir, "inner"))
  end

  test "an empty allowed_commands list denies every command", %{tmp_dir: cwd} do
    bash = tool(cwd, "bash", ToolPolicy.custom(allowed_commands: []))

    for command <- ["touch marker", "echo hi > marker", "true", "# nothing"] do
      result = run(bash, %{"command" => command})
      assert refused?(result), "ran #{command}"
      assert text(result) =~ "allowed_commands"
    end

    refute File.exists?(Path.join(cwd, "marker"))

    for name <- ["background", "pty"] do
      params = %{"command" => "touch marker", name_param(name) => true}
      assert refused?(run(bash, params))
    end

    refute File.exists?(Path.join(cwd, "marker"))
  end

  defp name_param("background"), do: "run_in_background"
  defp name_param("pty"), do: "pty"

  test "allowed_commands admits only the listed command prefixes", %{tmp_dir: cwd} do
    bash = tool(cwd, "bash", ToolPolicy.custom(allowed_commands: ["git status", "echo"]))

    refute refused?(run(bash, %{"command" => "git status"}))
    refute refused?(run(bash, %{"command" => "echo ok | echo again"}))

    for command <- [
          "git push",
          "git status; touch marker",
          "git status && touch marker",
          "echo $(touch marker)",
          "git status > marker",
          "echo ok >> marker",
          "/tmp/git status",
          "FOO=1 git status",
          "sudo git status",
          "env git status",
          "$CMD status",
          "git statusx"
        ] do
      assert refused?(run(bash, %{"command" => command})), "ran #{command}"
    end

    refute File.exists?(Path.join(cwd, "marker"))

    # The env parameter can redirect PATH or BASH_ENV, so it is refused.
    assert refused?(run(bash, %{"command" => "git status", "env" => %{"BASH_ENV" => "x"}}))
  end

  test "routed execution-node bash calls enforce the same lists", %{tmp_dir: cwd} do
    dir = victim(cwd)
    policy = ToolPolicy.custom(blocked_commands: ["rm -rf"])
    {:ok, context} = ExecutionContext.new(run_id: "run-1", tool_policy: policy)
    {:ok, context} = ExecutionContext.for_remote(context, nil)
    {:ok, encoded} = ExecutionContext.encode(context)

    args = %{
      "version" => 1,
      "tool" => "bash",
      "arguments" => %{"command" => "rm -rf #{dir}"},
      "toolCallId" => "call-1",
      "toolIntent" => %{"recordedBy" => "controller", "toolCallId" => "call-1"},
      "sessionId" => "session-1",
      "runId" => "run-1",
      "executionContext" => encoded
    }

    assert {:ok, result} = ToolService.run(args, default_cwd: cwd)
    assert result["isError"]
    assert File.dir?(dir)
  end

  test "eval and debug cannot run arbitrary code under command lists", %{tmp_dir: cwd} do
    marker = Path.join(cwd, "eval-ran")

    for policy <- [
          ToolPolicy.custom(blocked_commands: ["rm -rf"]),
          ToolPolicy.custom(allowed_commands: ["git status"])
        ] do
      eval = tool(cwd, "eval", policy)

      result =
        run(eval, %{
          "language" => "js",
          "code" => "require('fs').writeFileSync(#{inspect(marker)}, 'x')"
        })

      assert refused?(result), text(result)
      refute File.exists?(marker)

      debug = tool(cwd, "debug", policy)
      assert refused?(run(debug, %{"action" => "launch", "program" => "/bin/sh"}))
    end
  end

  test "process input cannot type a blocked command into an allowed shell", %{tmp_dir: cwd} do
    dir = victim(cwd)
    policy = ToolPolicy.custom(blocked_commands: ["rm -rf"])
    session_id = "command-policy-input-#{System.unique_integer([:positive])}"
    recorder = CodingAgent.Test.ToolIntentRecorder.new(cwd)

    opts = [
      tool_policy: policy,
      include_extensions: false,
      include_mcp: false,
      session_id: session_id,
      tool_intent_recorder: recorder
    ]

    {:ok, bash} = ToolRegistry.get_tool(cwd, "bash", opts)
    {:ok, input} = ToolRegistry.get_tool(cwd, "process_input", opts)

    started = run(bash, %{"command" => "sh", "run_in_background" => true})
    refute started.is_error, text(started)
    process_id = started.details[:process_id] || started.details["process_id"]

    result = run(input, %{"process_id" => process_id, "input" => "rm -rf #{dir}\n"})
    assert refused?(result), text(result)

    run(input, %{"process_id" => process_id, "input" => "exit\n", "eof" => true})
    assert File.dir?(dir)
  end

  # A mix project whose mix.exs runs code as soon as any mix task loads it.
  defp hostile_mix_project(cwd) do
    marker = Path.join(cwd, "mix_ran")

    File.write!(Path.join(cwd, "mix.exs"), """
    File.write!(#{inspect(marker)}, "ran")

    defmodule Hostile.MixProject do
      use Mix.Project
      def project, do: [app: :hostile, version: "0.1.0"]
    end
    """)

    File.mkdir_p!(Path.join(cwd, "lib"))
    File.write!(Path.join(cwd, "lib/a.ex"), "defmodule A do\nend\n")
    marker
  end

  test "lsp_diagnostics refuses project diagnostics under command lists", %{tmp_dir: cwd} do
    marker = hostile_mix_project(cwd)

    for policy <- [
          ToolPolicy.custom(allowed_commands: []),
          ToolPolicy.custom(blocked_commands: ["rm -rf"])
        ] do
      result = run(tool(cwd, "lsp_diagnostics", policy), %{"path" => "lib/a.ex"})
      assert text(result) =~ "tool policy", "diagnostics ran: #{inspect(result)}"
      refute File.exists?(marker)
    end
  end

  test "write and edit refuse explicit diagnostics/format and skip implicit runs",
       %{tmp_dir: cwd} do
    marker = hostile_mix_project(cwd)
    policy = ToolPolicy.custom(allowed_commands: [])
    parent = self()

    formatter = fn path, opts ->
      send(parent, {:formatter_ran, path, opts})
      {:ok, :unchanged}
    end

    for name <- ["write", "edit"], option <- ["diagnostics", "format"] do
      params =
        if name == "write",
          do: %{"path" => "lib/b.ex", "content" => "defmodule B do\nend\n"},
          else: %{"path" => "lib/a.ex", "old_text" => "A do", "new_text" => "A2 do"}

      result = run(tool(cwd, name, policy), Map.put(params, option, true))
      assert text(result) =~ "tool policy", "#{name} #{option}: #{inspect(result)}"
    end

    refute File.exists?(Path.join(cwd, "lib/b.ex"))

    {:ok, write} =
      ToolRegistry.get_tool(cwd, "write",
        tool_policy: policy,
        diagnostics: true,
        format: true,
        format_file_fun: formatter,
        include_extensions: false,
        include_mcp: false,
        session_id: "command-policy-#{System.unique_integer([:positive])}",
        tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(cwd)
      )

    result = run(write, %{"path" => "lib/c.ex", "content" => "defmodule C do\nend\n"})
    refute text(result) =~ "tool policy"
    assert File.exists?(Path.join(cwd, "lib/c.ex"))
    refute_received {:formatter_ran, _, _}
    refute File.exists?(marker)
  end

  test "the formatter refuses to launch under command lists", %{tmp_dir: cwd} do
    path = Path.join(cwd, "a.ex")
    File.write!(path, "defmodule A do end\n")
    policy = ToolPolicy.custom(blocked_commands: ["rm"])
    parent = self()

    assert {:error, reason} =
             CodingAgent.Tools.LspFormatter.format_file(path, cwd: cwd, tool_policy: policy)

    assert reason =~ "tool policy"

    formatter = fn p, o ->
      send(parent, {:formatter_ran, p, o})
      {:ok, :formatted}
    end

    assert {false, nil} =
             CodingAgent.Tools.LspFormatter.after_write(path, true, cwd,
               tool_policy: policy,
               format_file_fun: formatter
             )

    refute_received {:formatter_ran, _, _}
  end

  describe "CommandPolicy" do
    alias CodingAgent.Tools.Bash.CommandPolicy

    test "a program entry admits its subcommands; a wrapper entry blocks wrapped commands" do
      allow = ToolPolicy.custom(allowed_commands: ["git", "npm"])
      assert :ok = CommandPolicy.check("git status", allow)
      assert :ok = CommandPolicy.check("npm install", allow)
      assert {:blocked, _} = CommandPolicy.check("curl http://example.com", allow)

      block = ToolPolicy.custom(allowed_commands: ["sudo apt"], blocked_commands: ["sudo"])
      assert {:blocked, message} = CommandPolicy.check("sudo apt install vim", block)
      assert message =~ "blocked_commands"
    end

    test "no lists, or no policy, restricts nothing; an invalid policy refuses" do
      for policy <- [nil, ToolPolicy.custom()] do
        assert :ok = CommandPolicy.check("rm -rf /tmp/x > y", policy)
        assert :ok = CommandPolicy.check_env(%{"PATH" => "/x"}, policy)
        refute CommandPolicy.restricted?(policy)
      end

      assert {:blocked, _} = CommandPolicy.check("true", %{allow: 42})
      assert CommandPolicy.restricted?(%{allow: 42})
    end

    test "process input that is not valid UTF-8 is still checked" do
      policy = ToolPolicy.custom(blocked_commands: ["rm -rf"])
      assert {:blocked, _} = CommandPolicy.check_blocked(<<0xFF, "\nrm -rf /x\n">>, policy)
      assert :ok = CommandPolicy.check_blocked(<<0xFF, "\nls\n">>, policy)
    end
  end
end
