defmodule CodingAgent.Tools.LspClangdTest do
  @moduledoc """
  Exercises the `lsp` tool against a real clangd. Skipped when clangd is not
  on PATH.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Lsp
  alias CodingAgent.Tools.Lsp.{Client, Text}

  @env "LEMON_LSP_CLANGD_COMMAND"

  unless System.find_executable("clangd"), do: @moduletag(skip: "clangd is not installed")

  setup do
    previous = System.get_env(@env)
    System.delete_env(@env)
    tmp = Path.join(System.tmp_dir!(), "lsp_clangd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp = Text.realpath(tmp)
    session_id = "lsp-clangd-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each(Client.list(session_id), &Client.stop(&1.pid))
      if previous, do: System.put_env(@env, previous)
      File.rm_rf!(tmp)
    end)

    File.write!(Path.join(tmp, "compile_flags.txt"), "-std=c11\n")
    File.write!(Path.join(tmp, "util.c"), "int add_numbers(int a, int b) { return a + b; }\n")

    File.write!(Path.join(tmp, "main.c"), """
    int add_numbers(int a, int b);
    /* 😀 */ static int twice(int v) { return add_numbers(v, v); }
    int main(void) {
      int total = add_numbers(1, 2);
      return totl + twice(total);
    }
    """)

    {:ok, tmp: tmp, opts: [session_id: session_id, filesystem_checkpoints: false]}
  end

  test "diagnoses, navigates, fixes and renames through clangd", %{tmp: tmp, opts: opts} do
    tool = Lsp.tool(tmp, opts)
    run = &tool.execute.("call", &1, nil, nil)
    text = fn %{content: [%{text: text}]} -> text end

    diagnostics = run.(%{"action" => "diagnostics", "file" => "main.c", "timeout" => 60})
    assert text.(diagnostics) =~ ~r/main\.c:5:10 \[error\] .*'totl'/

    definition =
      run.(%{
        "action" => "definition",
        "file" => "main.c",
        "line" => 2,
        "symbol" => "add_numbers"
      })

    # The emoji is one code point but two UTF-16 units; columns are code points.
    assert text.(definition) =~ "main.c:1:5"

    references =
      run.(%{
        "action" => "references",
        "file" => "main.c",
        "line" => 4,
        "symbol" => "add_numbers"
      })

    assert text.(references) =~ "main.c:2:42"
    assert text.(references) =~ "main.c:4:15"

    fix =
      run.(%{
        "action" => "code_actions",
        "file" => "main.c",
        "line" => 5,
        "apply" => true,
        "query" => "total"
      })

    assert text.(fix) =~ "Applied"
    assert File.read!(Path.join(tmp, "main.c")) =~ "return total + twice(total);"

    params = %{
      "action" => "rename",
      "file" => "main.c",
      "line" => 4,
      "symbol" => "total",
      "new_name" => "sum"
    }

    assert text.(run.(params)) =~ "main.c: 3 edits"
    refute File.read!(Path.join(tmp, "main.c")) =~ "int sum"

    run.(Map.put(params, "apply", true))

    assert File.read!(Path.join(tmp, "main.c")) =~
             "int sum = add_numbers(1, 2);\n  return sum + twice(sum);"

    after_fix = run.(%{"action" => "diagnostics", "file" => "main.c", "timeout" => 60})
    assert text.(after_fix) == "No diagnostics reported for main.c"
  end
end
