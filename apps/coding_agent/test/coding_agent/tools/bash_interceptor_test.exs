defmodule CodingAgent.Tools.Bash.InterceptorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.Interceptor
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir
  @opts [
    bash_config: %{interceptor: %{enabled: true}},
    available_tools: ~w(read grep find ls edit)
  ]

  for {command, tool} <- [
        {"cat file", "read"},
        {"head file", "read"},
        {"tail file", "read"},
        {"less file", "read"},
        {"more file", "read"},
        {"grep x file", "grep"},
        {"rg x", "grep"},
        {"find . -name '*.ex'", "find"},
        {"fd x", "find"},
        {"ls", "ls"},
        {"sed -i '' s/a/b/ file", "edit"},
        {"sed -e s/a/b/ --in-place file", "edit"},
        {"perl -pi -e s/a/b/ file", "edit"},
        {"perl -i.bak file", "edit"}
      ] do
    test "routes #{command} to #{tool}" do
      assert {:blocked, message} = Interceptor.check(unquote(command), @opts)
      assert message =~ "`#{unquote(tool)}`"
      assert message =~ "enabled = false"
    end
  end

  test "disabled by default and only matches available tools" do
    assert :ok = Interceptor.check("cat file", available_tools: ["read"])
    assert :ok = Interceptor.check("cat file", Keyword.put(@opts, :available_tools, ["grep"]))
    assert :ok = Interceptor.check("cat file", bash_config: %{interceptor: %{enabled: false}})
  end

  test "custom rules replace defaults" do
    opts = [
      available_tools: ["read"],
      bash_config: %{
        interceptor: %{
          enabled: true,
          rules: [%{"pattern" => "^xxcat\\s", "tool" => "read", "message" => "Custom guidance"}]
        }
      }
    ]

    assert {:blocked, message} = Interceptor.check("xxcat file", opts)
    assert message =~ "Custom guidance"
    assert :ok = Interceptor.check("cat file", opts)
  end

  test "stdin pipeline stages are exempt but first stages and independent commands are not" do
    for command <- [
          "git log | head -5",
          "printf x | grep x | tail -1",
          "git log |\n# comment\nhead -1",
          "git log |& head"
        ] do
      assert :ok = Interceptor.check(command, @opts)
    end

    for command <- [
          "cat a | sort",
          "git status && cat a",
          "git status || ls",
          "(cat a)",
          "echo $(cat a)",
          ~s|echo "$(cat a)"|,
          "echo `cat a`",
          "FOO=1 sudo -u root command cat a"
        ] do
      assert {:blocked, _} = Interceptor.check(command, @opts)
    end
  end

  test "quoted data and non-editing commands do not match" do
    for command <- [
          "echo 'cat a; ls'",
          ~s(printf "%s" "rg file | head"),
          "echo '$(cat a)'",
          "sed -n '1p' file",
          "perl -pe 's/a/b/' file",
          "catalog file"
        ] do
      assert :ok = Interceptor.check(command, @opts)
    end
  end

  test "every execution mode refuses before any command starts", %{tmp_dir: cwd} do
    marker = Path.join(cwd, "started")

    for mode <- [%{}, %{"run_in_background" => true}, %{"name" => "blocked-service"}] do
      params = Map.merge(%{"command" => "touch #{marker}; cat file"}, mode)
      assert %AgentToolResult{is_error: true} = Bash.execute("id", params, nil, nil, cwd, @opts)
      refute File.exists?(marker)
    end
  end

  test "rules see expanded internal URLs", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "data")

    opts = [
      available_tools: ["read"],
      session_id: "interceptor",
      context_guardrails: %{spill_dir: Path.join(cwd, "spill")},
      bash_config: %{
        interceptor: %{
          enabled: true,
          rules: [%{"pattern" => "file\\.txt", "tool" => "read", "message" => "expanded"}]
        }
      }
    ]

    {:ok, uri} = CodingAgent.Artifacts.register(path, cwd, opts)

    assert %AgentToolResult{is_error: true, content: [%{text: message} | _]} =
             Bash.execute("id", %{"command" => "cat #{uri}"}, nil, nil, cwd, opts)

    assert message =~ "expanded"
  end
end
