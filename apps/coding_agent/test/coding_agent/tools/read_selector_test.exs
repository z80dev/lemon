defmodule CodingAgent.Tools.ReadSelectorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    lines = Enum.map_join(1..10, "\n", &"line#{&1}")
    File.write!(Path.join(tmp_dir, "ten.txt"), lines)
    :ok
  end

  defp read(tmp_dir, path, extra \\ %{}) do
    Read.execute("call", Map.put(extra, "path", path), nil, nil, tmp_dir, [])
  end

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  test "N-M reads an inclusive range", %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "ten.txt:3-5")
    assert %AgentToolResult{details: %{start_line: 3, lines_shown: 3}} = result
    assert text(result) =~ "3: line3\n4: line4\n5: line5"
    refute text(result) =~ "6: line6"
    assert text(result) =~ ~r/^\[.*ten\.txt#[0-9A-F]+\]/
  end

  test "N+K, N and N- open-ended forms", %{tmp_dir: tmp_dir} do
    assert %AgentToolResult{details: %{start_line: 4, lines_shown: 2}} =
             read(tmp_dir, "ten.txt:4+2")

    for selector <- ["ten.txt:8", "ten.txt:8-"] do
      assert %AgentToolResult{details: %{start_line: 8, lines_shown: 3}} = read(tmp_dir, selector)
    end
  end

  test "-N reads the last N lines", %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "ten.txt:-2")
    assert %AgentToolResult{details: %{start_line: 9, lines_shown: 2}} = result
    assert text(result) =~ "9: line9\n10: line10"

    whole = read(tmp_dir, "ten.txt:-50")
    assert %AgentToolResult{details: %{start_line: 1, lines_shown: 10}} = whole
  end

  test ":raw drops line numbers and the snapshot header", %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "ten.txt:2-3:raw")
    assert text(result) == "line2\nline3"
    assert %AgentToolResult{details: %{raw: true, snapshot: nil}} = result

    assert text(read(tmp_dir, "ten.txt:raw:9")) == "line9\nline10"
  end

  test "an existing file whose name looks like a selector wins", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "notes:12"), "literal")
    assert text(read(tmp_dir, "notes:12")) =~ "1: literal"
  end

  test "a selector on a missing base keeps the not-found error", %{tmp_dir: tmp_dir} do
    assert {:error, message} = read(tmp_dir, "missing.txt:3-4")
    assert message =~ "missing.txt:3-4"
  end

  test "rejects invalid or conflicting selectors", %{tmp_dir: tmp_dir} do
    assert {:error, "Line selector :5-2 ends before it starts"} = read(tmp_dir, "ten.txt:5-2")
    assert {:error, "Line selectors are 1-based" <> _} = read(tmp_dir, "ten.txt:0-2")

    assert {:error, "Use either a path line selector or offset/limit, not both"} =
             read(tmp_dir, "ten.txt:1-2", %{"offset" => 3})

    assert {:error, "A path selector takes at most one line range" <> _} =
             read(tmp_dir, "ten.txt:1-2:3-4")
  end

  test "selectors page archive member text", %{tmp_dir: tmp_dir} do
    archive = Path.join(tmp_dir, "bundle.zip")
    member = Enum.map_join(1..6, "\n", &"m#{&1}")
    {:ok, _} = :zip.create(String.to_charlist(archive), [{~c"a.txt", member}])

    result = read(tmp_dir, "bundle.zip:a.txt:2-3")
    assert text(result) =~ "2: m2\n3: m3"
    refute text(result) =~ "4: m4"
  end
end
