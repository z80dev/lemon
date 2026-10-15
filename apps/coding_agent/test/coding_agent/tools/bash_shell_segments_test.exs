defmodule CodingAgent.Tools.Bash.ShellSegmentsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash.ShellSegments

  test "splits independent commands and tracks stdin consumers" do
    segments = ShellSegments.extract("git log | head -5 || cat a && ls; fd x\nrg y |& tail")
    assert Enum.map(segments, &hd(&1.argv)) == ~w(git head cat ls fd rg tail)
    assert Enum.map(segments, & &1.piped_stdin) == [false, true, false, false, false, false, true]
  end

  test "quotes, escaped operators and empty arguments remain single words" do
    assert [%{argv: ["echo", "cat a; git reset --hard", "a|b", "", "x y"]}] =
             ShellSegments.extract(~s(echo 'cat a; git reset --hard' a\\|b "" x\\ y))

    assert [%{argv: ["echo", "a\"b", "$x", "a\\q"]}] =
             ShellSegments.extract(~S(echo "a\"b" "\$x" "a\q"))
  end

  test "visits nested commands, including double-quoted substitutions and backticks" do
    for command <- ["echo $(cat a)", ~s|echo "$(cat a)"|, "(cat a)", "echo `cat a`"] do
      assert Enum.any?(ShellSegments.extract(command), &(&1.argv == ["cat", "a"]))
    end

    refute Enum.any?(ShellSegments.extract("echo '$(cat a)'"), &(&1.argv == ["cat", "a"]))
  end

  test "strips assignments and common execution prefixes" do
    for prefix <- [
          "A='a b'",
          "command --",
          "builtin",
          "exec -a name",
          "time -p",
          "nohup",
          "sudo -u root",
          "env -u HOME FOO=1"
        ] do
      assert [%{argv: ["cat", "a"]}] = ShellSegments.extract(prefix <> " cat a")
    end
  end

  test "preserves pipeline context across blank lines, comments and continuations" do
    assert [%{piped_stdin: false}, %{argv: ["head"], piped_stdin: true}] =
             ShellSegments.extract("git log |\n# comment\n\nhead")

    assert [%{argv: ["cat", "file"]}] = ShellSegments.extract("ca\\\nt file")
    assert [%{argv: ["echo", "hello#world"]}] = ShellSegments.extract("echo hello#world # cat a")
  end
end
