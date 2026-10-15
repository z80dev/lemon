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

  test "a single bounded range includes one line before and three after", %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "ten.txt:3-5")
    assert %AgentToolResult{details: %{start_line: 2, lines_shown: 7}} = result
    assert text(result) =~ Enum.map_join(2..8, "\n", &"#{&1}: line#{&1}")
    refute text(result) =~ "1: line1"
    refute text(result) =~ "9: line9"
    assert text(result) =~ ~r/^\[.*ten\.txt#[0-9A-F]+\]/
    assert result.details.snapshot == read(tmp_dir, "ten.txt").details.snapshot
  end

  test "bounded context clamps at both ends of the file", %{tmp_dir: tmp_dir} do
    assert %AgentToolResult{details: %{start_line: 1, lines_shown: 5}} =
             read(tmp_dir, "ten.txt:1-2")

    assert %AgentToolResult{details: %{start_line: 8, lines_shown: 3}} =
             read(tmp_dir, "ten.txt:9-15")
  end

  test "N+K, N and N- open-ended forms", %{tmp_dir: tmp_dir} do
    assert %AgentToolResult{details: %{start_line: 3, lines_shown: 6}} =
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

  test "comma windows sort and merge overlaps, duplicates and adjacent lines without context",
       %{tmp_dir: tmp_dir} do
    result = read(tmp_dir, "ten.txt:8-9,3-5,4-6,3,2")

    assert text(result) =~
             "2: line2\n3: line3\n4: line4\n5: line5\n6: line6\n…\n8: line8\n9: line9"

    refute text(result) =~ "1: line1"
    refute text(result) =~ "7: line7"
    refute text(result) =~ "10: line10"
    assert result.details.lines_shown == 7

    assert result.details.ranges == [
             %{start_line: 2, lines_shown: 5},
             %{start_line: 8, lines_shown: 2}
           ]

    assert length(Regex.scan(~r/^\[.*ten\.txt#[0-9A-F]+\]/m, text(result))) == 1
    assert result.details.snapshot == read(tmp_dir, "ten.txt").details.snapshot
    assert Read.truncated_output?(text(result))
  end

  test "individual comma lines and mixed counts are exact, including raw in either order",
       %{tmp_dir: tmp_dir} do
    assert text(read(tmp_dir, "ten.txt:9,2,5")) =~ "2: line2\n…\n5: line5\n…\n9: line9"

    for selector <- ["ten.txt:8,2+2,6-6:raw", "ten.txt:raw:8,2+2,6-6"] do
      result = read(tmp_dir, selector)
      assert text(result) == "line2\nline3\n…\nline6\n…\nline8"
      assert result.details.snapshot == nil
    end

    # A comma list stays exact even if merging leaves one window.
    assert text(read(tmp_dir, "ten.txt:3-4,4-5:raw")) == "line3\nline4\nline5"
    assert text(read(tmp_dir, "ten.txt:3,4")) =~ "3: line3\n4: line4"
    refute text(read(tmp_dir, "ten.txt:3,4")) =~ "5: line5"
  end

  test "multi-range reads share the line and byte budgets", %{tmp_dir: tmp_dir} do
    result = Read.execute("cap", %{"path" => "ten.txt:1-2,5-8"}, nil, nil, tmp_dir, max_lines: 3)
    assert result.details.lines_shown == 3
    assert result.details.truncation.reason == "max_lines"
    assert text(result) =~ "1: line1\n2: line2\n…\n5: line5"
    refute text(result) =~ "6: line6"

    between = Read.execute("cap", %{"path" => "ten.txt:1-2,5-8"}, nil, nil, tmp_dir, max_lines: 2)
    assert between.details.truncation.next_offset == 5
    assert Read.truncated_output?(text(between))

    File.write!(
      Path.join(tmp_dir, "long.txt"),
      Enum.map_join(1..10, "\n", &("#{&1} " <> String.duplicate("x", 100)))
    )

    bytes =
      Read.execute("cap", %{"path" => "long.txt:1-2,5-8:raw"}, nil, nil, tmp_dir, max_bytes: 500)

    assert bytes.details.lines_shown < 6
    assert bytes.details.truncation.reason == "max_bytes"
  end

  test "selector elisions cannot overwrite an existing source", %{tmp_dir: tmp_dir} do
    output = text(read(tmp_dir, "ten.txt:2,8:raw"))
    assert output == "line2\n…\nline8"

    assert {:error, "content looks like a truncated read output" <> _} =
             CodingAgent.Tools.Write.execute(
               "overwrite",
               %{"path" => "ten.txt", "content" => output},
               nil,
               nil,
               tmp_dir,
               []
             )

    assert File.read!(Path.join(tmp_dir, "ten.txt")) == Enum.map_join(1..10, "\n", &"line#{&1}")
  end

  test "an existing file whose name looks like a selector wins", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "notes:12"), "literal")
    assert text(read(tmp_dir, "notes:12")) =~ "1: literal"
    File.write!(Path.join(tmp_dir, "ten.txt:2-3,5:raw"), "literal list")
    assert text(read(tmp_dir, "ten.txt:2-3,5:raw")) =~ "1: literal list"
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

    assert {:error, "Line selector :5-2 ends before it starts"} = read(tmp_dir, "ten.txt:1,5-2")
    assert {:error, "Line selectors are 1-based" <> _} = read(tmp_dir, "ten.txt:0,2")

    assert {:error, "Comma-list selectors require bounded line windows"} =
             read(tmp_dir, "ten.txt:1,5-")

    assert {:error, "Use either a path line selector or offset/limit, not both"} =
             read(tmp_dir, "ten.txt:1,3", %{"limit" => 2})
  end

  test "selectors page archive member text", %{tmp_dir: tmp_dir} do
    archive = Path.join(tmp_dir, "bundle.zip")
    member = Enum.map_join(1..6, "\n", &"m#{&1}")
    {:ok, _} = :zip.create(String.to_charlist(archive), [{~c"a.txt", member}])

    result = read(tmp_dir, "bundle.zip:a.txt:2-3")
    assert text(result) =~ "2: m2\n3: m3"
    assert text(result) =~ "1: m1\n2: m2\n3: m3\n4: m4\n5: m5\n6: m6"
    assert text(read(tmp_dir, "bundle.zip:a.txt:2-3:raw")) == "m2\nm3"
    assert text(read(tmp_dir, "bundle.zip:a.txt:1,4-5")) == "1: m1\n…\n4: m4\n5: m5"
    assert text(read(tmp_dir, "bundle.zip:a.txt:1,4-5:raw")) == "m1\n…\nm4\nm5"
  end
end
