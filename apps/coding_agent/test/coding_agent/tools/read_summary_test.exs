defmodule CodingAgent.Tools.ReadSummaryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.{Read, Write}

  @moduletag :tmp_dir

  test "bare large code reads keep declarations and mark exact omitted ranges", %{tmp_dir: root} do
    path = Path.join(root, "large.ex")
    content = elixir_file(320)
    File.write!(path, content)
    result = read(root, path)
    text = text(result)

    assert result.details.summary
    assert result.details.immutable
    assert result.details.snapshot == nil
    assert result.details.total_lines == 320
    assert result.details.elided_ranges == [{3, 319}]
    assert result.details.truncation.reason == "structural_summary"
    assert text =~ "1: defmodule Large do"
    assert text =~ "2:   def work(arg) do"
    assert text =~ "320: end"
    assert text =~ "… [lines 3-319 elided]"
    refute text =~ "hidden_body"
    refute text =~ ~r/\[[^\n]*#[0-9A-F]{16}\]/
    assert text =~ "#{path}:3-319"
    assert text =~ "#{path}:raw"
    assert text =~ "offset=1"
    assert Read.truncated_output?(text)

    # Only an explicit re-read supplies an editable snapshot for source ranges.
    selected = read(root, path <> ":3-5")
    refute Map.get(selected.details, :summary, false)
    assert is_binary(selected.details.snapshot)
    assert text(selected) =~ "3:     hidden_body(arg)"
  end

  test "raw selectors, explicit windows, params and tool opts bypass summaries", %{tmp_dir: root} do
    path = Path.join(root, "large.ex")
    File.write!(path, elixir_file(320))

    for {params, opts} <- [
          {%{"path" => path, "offset" => 1}, []},
          {%{"path" => path, "limit" => 320}, []},
          {%{"path" => path, "summary" => false}, []},
          {%{"path" => path}, [structural_summary: false]},
          {%{"path" => path <> ":raw"}, []},
          {%{"path" => path <> ":1-320:raw"}, []}
        ] do
      result = Read.execute("full", params, nil, nil, root, opts)
      refute Map.get(result.details, :summary, false)
      assert text(result) =~ "hidden_body(arg)"
    end
  end

  test "eligibility includes the 300-line boundary, excludes non-code and files over 2 MiB", %{
    tmp_dir: root
  } do
    for {name, content, summary?} <- [
          {"small.ex", elixir_file(299), false},
          {"boundary.ex", elixir_file(300), true},
          {"text.txt", elixir_file(320), false},
          {"large.ex", elixir_file(320) <> String.duplicate("x", 2 * 1024 * 1024), false}
        ] do
      path = Path.join(root, name)
      File.write!(path, content)
      result = read(root, path)
      assert Map.get(result.details, :summary, false) == summary?
    end
  end

  test "scanner preserves multiline Python signatures but not docstring declarations", %{
    tmp_dir: root
  } do
    path = Path.join(root, "outline.py")

    lines =
      [
        "class Thing:",
        "    \"\"\"",
        "    def not_a_function():",
        "    \"\"\"",
        "    def first(",
        "        self,",
        "        argument,",
        "    ):",
        "        hidden_body = argument"
      ] ++
        List.duplicate("        hidden_body += 1", 300) ++
        ["    def second(self):", "        return 2"]

    File.write!(path, Enum.join(lines, "\n"))
    result = read(root, path)
    assert text(result) =~ "1: class Thing:"
    assert text(result) =~ "5:     def first("
    assert text(result) =~ "7:         argument,"
    assert text(result) =~ "8:     ):"
    assert text(result) =~ "310:     def second(self):"
    refute text(result) =~ "not_a_function"
    refute text(result) =~ "hidden_body"
  end

  test "brace scanner ignores string/comment braces and keeps class methods", %{tmp_dir: root} do
    path = Path.join(root, "outline.ts")

    lines =
      ["export class Thing {", "  method() {", "    const text = \"} class Fake {\";"] ++
        List.duplicate("    hidden_body();", 300) ++
        [
          "  }",
          "  /*",
          "  function notReal() {",
          "  */",
          "  next() {",
          "    return 2;",
          "  }",
          "}"
        ]

    File.write!(path, Enum.join(lines, "\n"))
    result = read(root, path)
    assert text(result) =~ "1: export class Thing {"
    assert text(result) =~ "2:   method() {"
    assert text(result) =~ "308:   next() {"
    refute text(result) =~ "hidden_body"
    refute text(result) =~ "notReal"
    refute text(result) =~ "Fake"
  end

  test "common declaration forms remain visible", %{tmp_dir: root} do
    for {extension, declaration} <- [
          {"rs", "pub struct Thing {"},
          {"rs", "impl Thing {"},
          {"go", "func work() {"},
          {"java", "public class Thing {"},
          {"cpp", "int work() {"},
          {"swift", "struct Thing {"}
        ] do
      path = Path.join(root, "outline." <> extension)

      File.write!(
        path,
        declaration <> "\n" <> String.duplicate("    hidden_body();\n", 310) <> "}\n"
      )

      result = read(root, path)
      assert result.details.summary
      assert text(result) =~ "1: " <> declaration
      refute text(result) =~ "hidden_body"
    end
  end

  test "BOM and CRLF do not shift summary line numbers or tracked raw digest", %{tmp_dir: root} do
    path = Path.join(root, "windows.ex")
    content = "\uFEFF" <> String.replace(elixir_file(320), "\n", "\r\n")
    File.write!(path, content)
    scope = "summary-#{System.unique_integer([:positive])}"
    opts = [session_id: scope, session_pid: self()]
    on_exit(fn -> FileReadTracker.forget_session(scope) end)
    result = Read.execute("read", %{"path" => path}, nil, nil, root, opts)
    assert text(result) =~ "1: defmodule Large do"
    refute text(result) =~ "\r"
    assert FileReadTracker.check(opts, path, content) == :ok
    assert FileReadTracker.check(opts, path, content <> "changed") == {:error, :stale}
  end

  test "summary marker and footer cannot be copied over existing files", %{tmp_dir: root} do
    path = Path.join(root, "large.ex")
    content = elixir_file(320)
    File.write!(path, content)
    summary = read(root, path) |> text()

    for output <- [summary, "… [lines 3-319 elided]", List.last(String.split(summary, "\n"))] do
      assert Read.truncated_output?(output)

      assert {:error, message} =
               Write.execute(
                 "overwrite",
                 %{"path" => path, "content" => output},
                 nil,
                 nil,
                 root,
                 []
               )

      assert message =~ "content looks like a truncated read output"
      assert File.read!(path) == content
    end
  end

  test "summary output honors byte and line budgets, including omitted declarations", %{
    tmp_dir: root
  } do
    path = Path.join(root, "many.py")
    File.write!(path, Enum.map_join(1..400, "\n", &"def function_#{&1}(): pass"))

    result =
      Read.execute("bounded", %{"path" => path}, nil, nil, root, max_bytes: 1800, max_lines: 20)

    assert result.details.summary
    assert byte_size(text(result)) <= 1800
    assert length(String.split(text(result), "\n")) <= 20
    assert List.last(result.details.elided_ranges) |> elem(1) == 400
    assert text(result) =~ "Re-read needed bodies"
  end

  test "ACP summaries use the authoritative unsaved buffer, never the disk", %{tmp_dir: root} do
    path = Path.join(root, "buffer.ex")
    File.write!(path, "disk only")
    run_id = "summary-acp-#{System.unique_integer([:positive])}"
    :ok = LemonCore.ACPClientBridge.register(run_id)

    task =
      Task.async(fn ->
        Read.execute("acp", %{"path" => path}, nil, nil, root,
          run_id: run_id,
          acp_client_fs_read_text_file: true
        )
      end)

    assert_receive {:acp_client_request,
                    %{method: "fs/read_text_file", reply_to: reply_to, ref: ref}},
                   1000

    send(reply_to, {:acp_client_response, ref, %{"result" => %{"content" => elixir_file(320)}}})
    result = Task.await(task)
    assert result.details.acp_client
    assert result.details.summary
    assert result.details.snapshot == nil
    assert text(result) =~ "1: defmodule Large do"
    refute text(result) =~ "disk only"
  end

  defp elixir_file(lines) do
    Enum.join(
      ["defmodule Large do", "  def work(arg) do"] ++
        List.duplicate("    hidden_body(arg)", lines - 4) ++ ["  end", "end"],
      "\n"
    ) <> "\n"
  end

  defp read(root, path), do: Read.execute("summary", %{"path" => path}, nil, nil, root, [])
  defp text(%{content: [%{text: text}]}), do: text
end
