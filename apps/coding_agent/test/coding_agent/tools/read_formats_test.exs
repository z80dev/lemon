defmodule CodingAgent.Tools.ReadFormatsTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Tools.{ReadFormats, ReadFormatText, ReadFormatCommand}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{TextContent, ImageContent}

  @moduletag :tmp_dir

  test "unsupported text and literal colon filenames fall through", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "ordinary.txt"), "plain")
    File.write!(Path.join(cwd, "literal.zip:member"), "literal")
    assert :not_supported = read("ordinary.txt", cwd)
    assert :not_supported = read("literal.zip:member", cwd)
    assert :not_supported = read("missing.txt", cwd)
  end

  test "impossibly small text budgets return guidance instead of oversized output" do
    assert {:error, message} = ReadFormatText.result("x", "source", %{}, nil, max_bytes: 1)
    assert message =~ "numbered line"
  end

  test "directory reads delegate metadata and include hidden entries", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, ".hidden"), "hidden")
    File.mkdir!(Path.join(cwd, "child"))
    assert {:ok, result} = read(".", cwd)
    assert result.details.format == :directory
    assert result.details.is_directory
    assert result.details.total_entries == 2
    assert text(result) =~ ".hidden"
    assert text(result) =~ "child"
    assert text(result) =~ "d d"
    assert text(result) =~ "1: "
  end

  test "ZIP lists exact member names and reads numbered member text", %{tmp_dir: cwd} do
    zip(cwd, "bundle.zip", [{"src/main.ex", "first\nsecond\nthird\n"}, {"README.md", "hello"}])
    assert {:ok, listing} = read("bundle.zip", cwd)
    assert listing.details.total_entries == 2
    assert text(listing) =~ "README.md"
    assert text(listing) =~ "src/main.ex"

    assert {:ok, member} = read("bundle.zip:src/main.ex", cwd, %{"offset" => 2, "limit" => 1})
    assert text(member) =~ "2: second"
    refute text(member) =~ "first"
    assert member.details.total_lines == 3
    assert member.details.next_offset == 3
    assert member.details.truncation.reason == "limit"
    assert member.details.full_source == Path.join(cwd, "bundle.zip:src/main.ex")
    assert member.details.immutable
    refute Map.has_key?(member.details, :snapshot)
    refute File.exists?(Path.join(cwd, "src"))
  end

  test "ZIP subtree listing works without explicit directory members", %{tmp_dir: cwd} do
    zip(cwd, "bundle.zip", [{"src/a.txt", "a"}, {"src/b.txt", "b"}, {"root.txt", "r"}])
    assert {:ok, result} = read("bundle.zip:src/", cwd)
    assert result.details.total_entries == 2
    assert text(result) =~ "src/a.txt"
    refute text(result) =~ "root.txt"
    assert {:error, message} = read("bundle.zip:absent", cwd)
    assert message =~ "member not found"
  end

  test "ZIP root entry pagination retains complete source", %{tmp_dir: cwd} do
    zip(cwd, "bundle.zip", [{"a", "1"}, {"b", "2"}, {"c", "3"}])
    assert {:ok, result} = read("bundle.zip", cwd, %{"offset" => 2, "limit" => 1})
    assert text(result) =~ "2: b"
    assert result.details.next_offset == 3
    assert result.details.full_source == Path.join(cwd, "bundle.zip")
  end

  test "TAR and gzip TAR read in memory without filesystem extraction", %{tmp_dir: cwd} do
    for {name, opts} <- [
          {"bundle.tar", []},
          {"bundle.tgz", [:compressed]},
          {"bundle.tar.gz", [:compressed]}
        ] do
      path = Path.join(cwd, name)

      :ok =
        :erl_tar.create(String.to_charlist(path), [{~c"dir/member.txt", "tar text\nnext"}], opts)

      assert {:ok, listing} = read(name, cwd)
      assert text(listing) =~ "dir/member.txt"
      assert {:ok, member} = read(name <> ":dir/member.txt", cwd)
      assert text(member) =~ "1: tar text"
      assert text(member) =~ "2: next"
      refute File.exists?(Path.join(cwd, "dir"))
    end
  end

  test "archive binary errors retain exact member source", %{tmp_dir: cwd} do
    zip(cwd, "binary.zip", [{"data.bin", <<0, 1, 2>>}])
    assert {:error, message} = read("binary.zip:data.bin", cwd)
    assert message =~ "binary"
    assert message =~ "binary.zip:data.bin"
  end

  test "archive image members return actual image bytes", %{tmp_dir: cwd} do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/f9sAAAAASUVORK5CYII="
      )

    zip(cwd, "images.zip", [{"pixel.png", png}])

    assert {:ok, %AgentToolResult{content: [%ImageContent{} = image], details: details}} =
             read("images.zip:pixel.png", cwd)

    assert Base.decode64!(image.data) == png
    assert image.mime_type == "image/png"
    assert details.full_source == Path.join(cwd, "images.zip:pixel.png")
  end

  test "real image previews bound dimensions and retain original bytes", %{tmp_dir: cwd} do
    path = Path.join(cwd, "wide.png")
    original = png(2048, 4)
    File.write!(path, original)

    case ReadFormats.image_backend() do
      {:ok, %{name: :sips}} ->
        assert {:ok,
                %AgentToolResult{
                  content: [%TextContent{}, %ImageContent{} = image],
                  details: details
                }} = read("wide.png", cwd)

        assert details.original_width == 2048
        assert details.original_height == 4
        assert details.width <= 1568
        assert details.height <= 1568
        assert details.resized
        assert byte_size(Base.decode64!(image.data)) <= 4 * 1024 * 1024
        assert image.mime_type == "image/png"
        assert details.full_source == path
        assert File.read!(path) == original

      {:error, message} ->
        assert message =~ "resize externally"
        assert :not_supported = read("wide.png", cwd)
    end
  end

  test "real image previews also bound encoded file bytes", %{tmp_dir: cwd} do
    path = Path.join(cwd, "pixels.png")
    File.write!(path, png(256, 256))

    case ReadFormats.image_backend() do
      {:ok, _} ->
        assert {:ok,
                %AgentToolResult{
                  content: [%TextContent{}, %ImageContent{} = image],
                  details: details
                }} =
                 read("pixels.png", cwd, %{}, image_max_bytes: 2048)

        assert byte_size(Base.decode64!(image.data)) <= 2048
        assert details.size <= 2048
        assert details.resized

      {:error, _} ->
        assert :not_supported = read("pixels.png", cwd)
    end
  end

  test "decoded archive members and input sizes have explicit ceilings", %{tmp_dir: cwd} do
    zip(cwd, "large.zip", [{"large.txt", String.duplicate("x", 100)}])

    assert {:error, member_error} =
             read("large.zip:large.txt", cwd, %{}, format_max_member_bytes: 20)

    assert member_error =~ "decoded-member limit"
    assert {:error, input_error} = read("large.zip", cwd, %{}, format_max_input_bytes: 1)
    assert input_error =~ "input limit"
  end

  test "malformed archives return backend errors", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "bad.zip"), "not a zip")
    File.write!(Path.join(cwd, "bad.tar"), "not a tar")
    assert {:error, _} = read("bad.zip", cwd)
    assert {:error, _} = read("bad.tar", cwd)
  end

  test "notebooks render indexed sources, executions, streams, MIME text and errors", %{
    tmp_dir: cwd
  } do
    notebook(cwd)
    assert {:ok, result} = read("sample.ipynb", cwd)
    output = text(result)
    assert output =~ "Cell 1 [markdown]"
    assert output =~ "# Notebook heading"
    assert output =~ "Cell 2 [code] execution_count=7"
    assert output =~ "print(42)"
    assert output =~ "stdout:"
    assert output =~ "42"
    assert output =~ "rendered result"
    assert output =~ "image/png"
    refute output =~ "DO_NOT_PRINT_BASE64"
    assert output =~ "ValueError: broken"
    assert output =~ "trace line 1\n"
    assert result.details.total_cells == 3
    assert result.details.full_source == Path.join(cwd, "sample.ipynb")
  end

  test "notebook cell selection composes with line selection", %{tmp_dir: cwd} do
    notebook(cwd)

    assert {:ok, result} =
             read("sample.ipynb", cwd, %{"cell" => 2, "cell_limit" => 1, "limit" => 2})

    assert text(result) =~ "1: === Cell 2"
    assert text(result) =~ "2: print(42)"
    refute text(result) =~ "Notebook heading"
    assert result.details.cells_shown == 1
    assert result.details.next_cell == 3
    assert result.details.next_offset == 3
    assert {:error, message} = read("sample.ipynb", cwd, %{"cell" => 20})
    assert message =~ "beyond"
  end

  test "invalid and empty notebooks are distinguished", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "invalid.ipynb"), "{")
    assert {:error, message} = read("invalid.ipynb", cwd)
    assert message =~ "valid JSON"
    File.write!(Path.join(cwd, "wrong.ipynb"), Jason.encode!(%{"cells" => ["not an object"]}))
    assert {:error, message} = read("wrong.ipynb", cwd)
    assert message =~ "JSON objects"
    File.write!(Path.join(cwd, "empty.ipynb"), Jason.encode!(%{"cells" => [], "nbformat" => 4}))
    assert {:ok, result} = read("empty.ipynb", cwd)
    assert text(result) =~ "empty notebook"
  end

  test "rich text bounds long UTF-8 lines and preserves continuation source", %{tmp_dir: cwd} do
    source = Path.join(cwd, "source.zip:big.txt")

    assert {:ok, result} =
             ReadFormatText.result(String.duplicate("é", 2000) <> "\nnext\n", source, %{}, nil,
               max_bytes: 1024
             )

    assert String.valid?(text(result))
    assert byte_size(text(result)) <= 1024
    assert result.details.total_lines == 2
    assert result.details.truncation.reason == "long_line"
    assert result.details.full_source == source
    assert result.details.next_offset == 2
  end

  test "rich text line caps can be continued without trailing-LF phantom lines", %{tmp_dir: cwd} do
    source = Path.join(cwd, "sample.ipynb")
    assert {:ok, first} = ReadFormatText.result("a\n\nb\n", source, %{}, nil, max_lines: 2)
    assert first.details.total_lines == 3
    assert first.details.lines_shown == 2
    assert first.details.next_offset == 3
    assert {:ok, last} = ReadFormatText.result("a\n\nb\n", source, %{"offset" => 3}, nil, [])
    assert text(last) == "3: b"
    assert is_nil(last.details.next_offset)
    assert {:error, _} = ReadFormatText.result("a\n", source, %{"offset" => 2}, nil, [])
  end

  test "PDF availability produces extracted real page text or actionable setup", %{tmp_dir: cwd} do
    path = Path.join(cwd, "pages.pdf")
    File.write!(path, pdf(["Alpha page", "Beta page"]))
    interpreter = Path.expand(".lemon/read-formats-venv/bin/python3")
    opts = if File.regular?(interpreter), do: [pdf_python: interpreter], else: []

    case ReadFormats.pdf_backend(cwd, opts) do
      {:ok, %{name: backend}} ->
        assert backend in [:pdftotext, :mutool, :python]
        assert {:ok, result} = read("pages.pdf", cwd, %{}, opts)
        assert text(result) =~ "Page 1"
        assert text(result) =~ "Alpha page"
        assert text(result) =~ "Page 2"
        assert text(result) =~ "Beta page"
        assert result.details.full_source == path
        assert {:ok, selected} = read("pages.pdf", cwd, %{"page" => 2, "page_limit" => 1}, opts)
        assert text(selected) =~ "Page 2"
        assert text(selected) =~ "Beta page"
        refute text(selected) =~ "Alpha page"

      {:error, message} ->
        assert message =~ "pypdf"
        assert message =~ "venv"
        assert {:error, ^message} = read("pages.pdf", cwd, %{}, opts)
    end
  end

  test "cancelled reads and invalid selectors fail before work", %{tmp_dir: cwd} do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    assert {:error, "Operation aborted"} = ReadFormats.read("missing.pdf", %{}, signal, cwd, [])

    for key <- ["offset", "limit", "page", "page_limit", "cell", "cell_limit"] do
      assert {:error, message} = read("missing.pdf", cwd, %{key => 0})
      assert message =~ key
    end
  end

  test "document commands enforce real output and time limits" do
    executable = System.find_executable("sh")
    assert {:ok, "hello"} = ReadFormatCommand.run(executable, ["-c", "printf hello"], nil)

    assert {:ok, <<0, "out", 0, "err">>} =
             ReadFormatCommand.run(
               executable,
               ["-c", ~S(printf '\000out\000'; printf err >&2)],
               nil
             )

    assert {:error, "Document backend exited with status 7: failure"} =
             ReadFormatCommand.run(executable, ["-c", "printf failure >&2; exit 7"], nil)

    assert {:error, bounded} =
             ReadFormatCommand.run(executable, ["-c", "printf 123456789"], nil, max_bytes: 4)

    assert bounded =~ "exceeds"

    assert {:error, timeout} =
             ReadFormatCommand.run(executable, ["-c", "sleep 1"], nil, timeout_ms: 10)

    assert timeout =~ "timed out"
  end

  test "immediate commands survive delayed group witnessing" do
    capture = fn pid ->
      Process.sleep(100)
      CodingAgent.BashExecutor.capture_workload_group(pid)
    end

    for _ <- 1..10 do
      assert {:ok, "hello"} =
               ReadFormatCommand.run(System.find_executable("sh"), ["-c", "printf hello"], nil,
                 capture_group: capture
               )
    end
  end

  test "an immediately exiting backend retains ownership of redirected children", %{tmp_dir: dir} do
    parent = self()
    sh = System.find_executable("sh")
    script = ~S|(sleep 60 </dev/null >/dev/null 2>&1 & echo $! > "$1/child"); echo $$ > "$1/root"|
    sentinel = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
    {:os_pid, sentinel_pid} = Port.info(sentinel, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(sentinel_pid)]) end)

    for cancellation <- [:abort, :death] do
      signal = AbortSignal.new()

      capture = fn pid ->
        group = CodingAgent.BashExecutor.capture_workload_group(pid)
        send(parent, {:witnessed, self()})

        receive do
          :start -> group
        end
      end

      {caller, ref} =
        spawn_monitor(fn ->
          result =
            ReadFormatCommand.run(sh, ["-c", script, "sh", dir], signal, capture_group: capture)

          send(parent, {:result, result})
        end)

      assert_receive {:witnessed, guardian}, 5_000
      :erlang.suspend_process(caller)
      send(guardian, :start)
      [root, child] = await_backend(dir)
      assert_eventually(fn -> not os_alive?(root) end, timeout: 5_000)
      assert os_alive?(child)

      case cancellation do
        :abort ->
          AbortSignal.abort(signal)
          :erlang.resume_process(caller)
          assert_receive {:result, {:error, "Operation aborted"}}, 5_000
          assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

        :death ->
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
      end

      assert_eventually(fn -> not os_alive?(child) end, timeout: 5_000)
      assert os_alive?(sentinel_pid)
    end
  end

  test "closed ports still clean up witnessed descendants on cancellation", %{tmp_dir: dir} do
    sh = System.find_executable("sh")

    script =
      ~S|(sleep 60 </dev/null >/dev/null 2>&1 & echo $! > "$1/child"); echo $$ > "$1/root"; while [ ! -f "$1/exit" ]; do sleep 0.02; done|

    sentinel = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
    {:os_pid, sentinel_pid} = Port.info(sentinel, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(sentinel_pid)]) end)

    for cancellation <- [:death, :abort] do
      signal = AbortSignal.new()
      parent = self()

      {caller, ref} =
        spawn_monitor(fn ->
          result = ReadFormatCommand.run(sh, ["-c", script, "sh", dir], signal)
          send(parent, {:result, result})
        end)

      [root, child] = await_backend(dir)
      :erlang.suspend_process(caller)
      # Let the guardian witness the child while the root is held alive.
      Process.sleep(200)
      File.write!(Path.join(dir, "exit"), "")
      assert_eventually(fn -> not os_alive?(root) end, timeout: 5_000)
      assert os_alive?(child)

      case cancellation do
        :death ->
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

        :abort ->
          AbortSignal.abort(signal)
          :erlang.resume_process(caller)
          assert_receive {:result, {:error, "Operation aborted"}}, 5_000
          assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      end

      assert_eventually(fn -> not os_alive?(child) end, timeout: 5_000)
      assert os_alive?(sentinel_pid)
      File.rm!(Path.join(dir, "exit"))
    end
  end

  test "abort and a killed caller stop the whole backend group, nothing else", %{tmp_dir: dir} do
    sh = System.find_executable("sh")
    # `child` leaves its subshell (reparented) but stays in the backend's group.
    script = ~S|(sleep 60 & echo $! > "$1/child"); echo $$ > "$1/root"; exec sleep 60|
    sentinel = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
    {:os_pid, sentinel_pid} = Port.info(sentinel, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(sentinel_pid)]) end)

    signal = AbortSignal.new()
    task = Task.async(fn -> ReadFormatCommand.run(sh, ["-c", script, "sh", dir], signal) end)
    backend = await_backend(dir)
    AbortSignal.abort(signal)
    assert Task.await(task, 5_000) == {:error, "Operation aborted"}
    assert_eventually(fn -> not Enum.any?(backend, &os_alive?/1) end, timeout: 5_000)

    {caller, ref} =
      spawn_monitor(fn -> ReadFormatCommand.run(sh, ["-c", script, "sh", dir], nil) end)

    backend = await_backend(dir)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_eventually(fn -> not Enum.any?(backend, &os_alive?/1) end, timeout: 5_000)

    task =
      Task.async(fn ->
        ReadFormatCommand.run(sh, ["-c", script, "sh", dir], nil, timeout_ms: 500)
      end)

    backend = await_backend(dir)
    assert {:error, message} = Task.await(task, 5_000)
    assert message =~ "timed out"
    assert_eventually(fn -> not Enum.any?(backend, &os_alive?/1) end, timeout: 5_000)

    assert os_alive?(sentinel_pid)
  end

  defp await_backend(dir) do
    files = [Path.join(dir, "root"), Path.join(dir, "child")]

    assert_eventually(
      fn -> Enum.all?(files, &(File.exists?(&1) and File.read!(&1) =~ ~r/^\d+\n$/)) end,
      timeout: 5_000
    )

    pids = Enum.map(files, &(&1 |> File.read!() |> String.trim() |> String.to_integer()))
    Enum.each(files, &File.rm!/1)
    pids
  end

  defp os_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  defp read(path, cwd, params \\ %{}, opts \\ []),
    do: ReadFormats.read(path, params, nil, cwd, opts)

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  defp zip(cwd, name, members) do
    path = Path.join(cwd, name)
    files = Enum.map(members, fn {name, bytes} -> {String.to_charlist(name), bytes} end)
    {:ok, {_name, bytes}} = :zip.create(String.to_charlist(name), files, [:memory])
    File.write!(path, bytes)
  end

  defp notebook(cwd) do
    cells = [
      %{"cell_type" => "markdown", "source" => ["# Notebook heading\n", "explanation"]},
      %{
        "cell_type" => "code",
        "execution_count" => 7,
        "source" => ["print(42)\n"],
        "outputs" => [
          %{"output_type" => "stream", "name" => "stdout", "text" => ["42\n"]},
          %{
            "output_type" => "display_data",
            "data" => %{"text/plain" => ["rendered result"], "image/png" => "DO_NOT_PRINT_BASE64"}
          }
        ]
      },
      %{
        "cell_type" => "code",
        "execution_count" => nil,
        "source" => "raise ValueError('broken')",
        "outputs" => [
          %{
            "output_type" => "error",
            "ename" => "ValueError",
            "evalue" => "broken",
            "traceback" => ["trace line 1", "trace line 2"]
          }
        ]
      }
    ]

    File.write!(
      Path.join(cwd, "sample.ipynb"),
      Jason.encode!(%{"cells" => cells, "nbformat" => 4, "nbformat_minor" => 5})
    )
  end

  defp png(width, height) do
    pixels =
      for index <- 0..(width * height - 1), into: <<>> do
        <<rem(index, 256), rem(div(index, 256), 256), rem(index * 37, 256)>>
      end

    row_bytes = width * 3
    rows = for <<row::binary-size(^row_bytes) <- pixels>>, into: <<>>, do: <<0, row::binary>>
    header = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      png_chunk("IHDR", header) <>
      png_chunk("IDAT", :zlib.compress(rows)) <> png_chunk("IEND", "")
  end

  defp png_chunk(name, bytes) do
    <<byte_size(bytes)::32, name::binary, bytes::binary, :erlang.crc32(name <> bytes)::32>>
  end

  defp pdf(page_texts) do
    page_count = length(page_texts)
    kids = Enum.map_join(0..(page_count - 1), " ", &"#{4 + &1 * 2} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{page_count} >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
      ] ++
        Enum.flat_map(Enum.with_index(page_texts), fn {text, index} ->
          stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"

          page =
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents #{5 + index * 2} 0 R >>"

          [page, "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"]
        end)

    {body, offsets} =
      Enum.reduce(Enum.with_index(objects, 1), {"%PDF-1.4\n", []}, fn {object, index},
                                                                      {body, offsets} ->
        {body <> "#{index} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    xref =
      Enum.map_join(
        offsets,
        "",
        &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n")
      )

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      xref <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
