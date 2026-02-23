defmodule CodingAgent.Tools.ExecSecurityTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.ExecSecurity

  # ============================================================================
  # check/1 - clean commands
  # ============================================================================

  describe "check/1 - clean commands pass through" do
    test "simple command with no obfuscation" do
      assert ExecSecurity.check("ls -la") == :ok
    end

    test "command with path argument" do
      assert ExecSecurity.check("cat /etc/hosts") == :ok
    end

    test "command with quoted string argument" do
      assert ExecSecurity.check(~s(echo "hello world")) == :ok
    end

    test "command with single-quoted argument" do
      assert ExecSecurity.check("echo 'hello world'") == :ok
    end

    test "piped commands" do
      assert ExecSecurity.check("ls | grep foo") == :ok
    end

    test "command with environment variable assignment prefix" do
      # FOO=bar is an assignment, not a substitution; $FOO on its own IS flagged
      assert ExecSecurity.check("FOO=bar ./script.sh") == :ok
    end

    test "command with redirect" do
      assert ExecSecurity.check("echo hello > /tmp/out.txt") == :ok
    end

    test "command with numeric argument" do
      assert ExecSecurity.check("sleep 5") == :ok
    end

    test "multi-word command" do
      assert ExecSecurity.check("git commit -m 'fix bug'") == :ok
    end

    test "empty string" do
      assert ExecSecurity.check("") == :ok
    end
  end

  # ============================================================================
  # check/1 - backtick substitution
  # ============================================================================

  describe "check/1 - backtick substitution" do
    test "detects backtick wrapped command" do
      assert ExecSecurity.check("`cat /etc/passwd`") ==
               {:obfuscated, "backtick substitution (`...`)"}
    end

    test "detects backtick substitution embedded in command" do
      assert ExecSecurity.check("echo `whoami`") ==
               {:obfuscated, "backtick substitution (`...`)"}
    end

    test "detects backtick substitution with spaces" do
      assert ExecSecurity.check("echo `ls -la /`") ==
               {:obfuscated, "backtick substitution (`...`)"}
    end

    test "single backtick with no closing is not flagged" do
      # Pattern requires content between two backticks
      assert ExecSecurity.check("echo `") == :ok
    end

    test "two adjacent backticks with nothing inside are not flagged" do
      assert ExecSecurity.check("echo ``") == :ok
    end
  end

  # ============================================================================
  # check/1 - command substitution $(...)
  # ============================================================================

  describe "check/1 - command substitution" do
    test "detects $(...) command substitution" do
      assert ExecSecurity.check("$(cat /etc/passwd)") ==
               {:obfuscated, "command substitution ($(..))"}
    end

    test "detects $(...) embedded in argument" do
      assert ExecSecurity.check("echo $(whoami)") ==
               {:obfuscated, "command substitution ($(..))"}
    end

    test "detects base64 encoding trick" do
      assert ExecSecurity.check("$(echo Y2F0IC9ldGMvcGFzc3dk | base64 -d)") ==
               {:obfuscated, "command substitution ($(..))"}
    end

    test "detects nested $(...)" do
      assert ExecSecurity.check("$(echo $(id))") ==
               {:obfuscated, "command substitution ($(..))"}
    end
  end

  # ============================================================================
  # check/1 - variable substitution ${VAR}
  # ============================================================================

  describe "check/1 - braced variable substitution" do
    test "detects ${VAR} substitution" do
      assert ExecSecurity.check("echo ${HOME}") ==
               {:obfuscated, "variable substitution (${VAR})"}
    end

    test "detects ${VAR} used as command" do
      assert ExecSecurity.check("${SHELL} -c 'id'") ==
               {:obfuscated, "variable substitution (${VAR})"}
    end

    test "detects ${VAR} with underscores" do
      assert ExecSecurity.check("echo ${MY_VAR}") ==
               {:obfuscated, "variable substitution (${VAR})"}
    end

    test "detects ${VAR} with numbers" do
      assert ExecSecurity.check("echo ${VAR1}") ==
               {:obfuscated, "variable substitution (${VAR})"}
    end
  end

  # ============================================================================
  # check/1 - simple variable substitution $VAR
  # ============================================================================

  describe "check/1 - simple variable substitution" do
    test "detects $VAR substitution" do
      assert ExecSecurity.check("echo $HOME") ==
               {:obfuscated, "variable substitution ($VAR)"}
    end

    test "detects $VAR used as command" do
      assert ExecSecurity.check("$SHELL -c 'id'") ==
               {:obfuscated, "variable substitution ($VAR)"}
    end

    test "detects $VAR with underscore prefix" do
      assert ExecSecurity.check("echo $_SECRET") ==
               {:obfuscated, "variable substitution ($VAR)"}
    end

    test "detects $VAR mid-string" do
      assert ExecSecurity.check("cat /tmp/$USER/file") ==
               {:obfuscated, "variable substitution ($VAR)"}
    end

    test "dollar sign followed by number is not a variable" do
      assert ExecSecurity.check("echo $1") == :ok
    end

    test "lone dollar sign is not a variable" do
      assert ExecSecurity.check("echo $") == :ok
    end
  end

  # ============================================================================
  # check/1 - string concatenation (single quotes)
  # ============================================================================

  describe "check/1 - empty single-quote concatenation" do
    test "detects c''a''t pattern" do
      assert ExecSecurity.check("c''a''t /etc/passwd") ==
               {:obfuscated, "string concatenation (x''y)"}
    end

    test "detects two-character split: ca''t" do
      assert ExecSecurity.check("ca''t /etc/shadow") ==
               {:obfuscated, "string concatenation (x''y)"}
    end

    test "detects split at word start: ''cat" do
      # The regex requires a letter before '', so ''cat alone is not flagged
      # but x''cat is
      assert ExecSecurity.check("x''cat") ==
               {:obfuscated, "string concatenation (x''y)"}
    end

    test "two single quotes not between letters are not flagged" do
      assert ExecSecurity.check("echo ''") == :ok
    end

    test "single-quoted empty string in argument is not flagged" do
      assert ExecSecurity.check("echo 'foo' '' 'bar'") == :ok
    end
  end

  # ============================================================================
  # check/1 - string concatenation (double quotes)
  # ============================================================================

  describe "check/1 - empty double-quote concatenation" do
    test ~s(detects c""a""t pattern) do
      assert ExecSecurity.check(~s(c""a""t /etc/passwd)) ==
               {:obfuscated, ~s|string concatenation (x""y)|}
    end

    test ~s(detects ca""t pattern) do
      assert ExecSecurity.check(~s(ca""t /etc/shadow)) ==
               {:obfuscated, ~s|string concatenation (x""y)|}
    end

    test ~s(two double-quotes not between letters are not flagged) do
      assert ExecSecurity.check(~s(echo "")) == :ok
    end
  end

  # ============================================================================
  # rejection_message/1
  # ============================================================================

  describe "rejection_message/1" do
    test "includes the technique name" do
      msg = ExecSecurity.rejection_message("backtick substitution (`...`)")
      assert msg =~ "backtick substitution (`...`)"
    end

    test "mentions obfuscation" do
      msg = ExecSecurity.rejection_message("some technique")
      assert msg =~ "obfuscation"
    end

    test "is a non-empty binary" do
      msg = ExecSecurity.rejection_message("x")
      assert is_binary(msg)
      assert String.length(msg) > 0
    end
  end

  # ============================================================================
  # Integration: bash tool rejects obfuscated commands
  # ============================================================================

  describe "bash tool integration" do
    alias CodingAgent.Tools.Bash
    alias AgentCore.Types.AgentToolResult
    alias Ai.Types.TextContent

    @moduletag :tmp_dir

    test "rejects backtick command in bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "`echo pwned`"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{error: :obfuscated_command}
             } = result

      assert text =~ "obfuscation"
      assert text =~ "backtick"
    end

    test "rejects $(...) command substitution in bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "echo $(id)"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{error: :obfuscated_command}} = result
    end

    test "rejects variable substitution in bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "echo $HOME"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{error: :obfuscated_command}} = result
    end

    test "rejects string concatenation in bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "c''a''t /etc/passwd"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{error: :obfuscated_command}} = result
    end

    test "allows clean commands through bash tool", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo hello"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "hello"
      refute match?(%AgentToolResult{details: %{error: :obfuscated_command}}, result)
    end
  end
end
