defmodule LemonCli.ContextCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-context-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.txt"), "token=secret\nhello CLI")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "packaged dispatch previews and resolves through LemonCore.Context", %{root: root} do
    preview =
      capture_io(fn ->
        assert CLI.run(["context", "preview", "@file:note.txt", "--root", root, "--json"]) == 0
      end)

    preview = Jason.decode!(preview)
    assert preview["mode"] == "preview"
    assert preview["selected_text"] == nil
    assert preview["summary"]["redaction_count"] == 1

    resolved =
      capture_io(fn ->
        assert CLI.run(["context", "resolve", "@file:note.txt", "--root", root, "--json"]) == 0
      end)

    resolved = Jason.decode!(resolved)
    assert resolved["mode"] == "resolve"
    assert resolved["selected_text"] =~ "token=[REDACTED]"
    assert resolved["selected_text"] =~ "hello CLI"
  end

  test "invalid command shapes return the usage exit code" do
    output = capture_io(:stderr, fn -> assert CLI.run(["context", "resolve"]) == 2 end)
    assert output =~ "At least one context reference is required"
  end
end
