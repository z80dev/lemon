defmodule CodingAgent.Tools.ReadPdfTrustTest do
  # Mutates the process-global PATH, so this module must not run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{AstGrep, Read, ReadFormats}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "local read never executes project or ancestor read-formats-venv interpreters", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "repo/nested")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(tmp_dir, "repo/.git"))
    markers = Enum.map([cwd, Path.join(tmp_dir, "repo"), tmp_dir], &install_sentinel/1)
    File.write!(Path.join(cwd, "doc.pdf"), "%PDF-1.4\n%%EOF\n")

    # Project-controlled PATH entries (relative, in-repo, venv bin) are not grants either.
    for name <- ["pdftotext", "mutool", "python3"] do
      File.ln_s!(Path.join(cwd, ".lemon/read-formats-venv/bin/python3"), Path.join(cwd, name))
    end

    isolate_path(tmp_dir, ["", ".", ".lemon/read-formats-venv/bin", cwd])

    File.cd!(cwd, fn ->
      assert {:error, message} = ReadFormats.read("doc.pdf", %{}, nil, cwd, [])
      assert message =~ "pdf_python"
      assert {:error, _} = ReadFormats.pdf_backend(cwd)

      assert {:error, _} =
               Read.execute("pdf", %{"path" => Path.join(cwd, "doc.pdf")}, nil, nil, cwd, [])

      tool = Read.tool(cwd)
      tool.execute.("pdf-tool", %{"path" => "doc.pdf"}, nil, nil)
    end)

    for marker <- markers, do: refute(File.exists?(marker), "executed #{marker}")
  end

  test "operator :pdf_python extracts text and always runs isolated (-I)", %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(cwd)
    project_marker = install_sentinel(cwd)
    File.write!(Path.join(cwd, "doc.pdf"), "%PDF-1.4\n%%EOF\n")
    isolate_path(tmp_dir, [])

    operator = Path.join(System.tmp_dir!(), "lemon-op-py-#{System.unique_integer([:positive])}")
    File.mkdir_p!(operator)
    on_exit(fn -> File.rm_rf!(operator) end)
    argv_log = Path.join(operator, "argv.log")
    python = Path.join(operator, "python3")

    File.write!(python, """
    #!/bin/sh
    printf '%s\\n' "$1" >> "#{argv_log}"
    case "$3" in
      *find_spec*) echo pypdf ;;
      *) printf '%s' '{"total_pages": 1, "pages": [{"page": 1, "text": "Operator page"}]}' ;;
    esac
    """)

    File.chmod!(python, 0o700)

    assert {:ok, %AgentToolResult{content: [%TextContent{text: text}]} = result} =
             ReadFormats.read("doc.pdf", %{}, nil, cwd, pdf_python: python)

    assert text =~ "Operator page"
    assert result.details.backend == :python
    first_args = argv_log |> File.read!() |> String.split("\n", trim: true)
    assert length(first_args) == 2
    assert Enum.all?(first_args, &(&1 == "-I"))
    refute File.exists?(project_marker)
  end

  @tag :pdf_python_library
  test "real operator Python extracts a real PDF without running project or PYTHONPATH code", %{
    tmp_dir: tmp_dir
  } do
    python = CodingAgent.TestPdfPython.executable()
    cwd = Path.join(tmp_dir, "project")
    hostile = Path.join(tmp_dir, "hostile-pythonpath")
    marker = Path.join(tmp_dir, "project-python-code-ran")

    for directory <- [cwd, hostile] do
      payload = "open(#{inspect(marker)}, 'a').write(__file__ + '\\n')\n"

      for module <- ["pypdf", "fitz", "pymupdf"] do
        File.mkdir_p!(Path.join(directory, module))
        File.write!(Path.join([directory, module, "__init__.py"]), payload)
      end

      for file <- [
            "json.py",
            "logging.py",
            "importlib.py",
            "sitecustomize.py",
            "usercustomize.py"
          ],
          do: File.write!(Path.join(directory, file), payload)
    end

    File.write!(Path.join(cwd, "doc.pdf"), pdf(["Fixture alpha", "Fixture beta"]))
    isolate_path(tmp_dir, [])
    put_env("PYTHONPATH", hostile <> ":" <> cwd)
    put_env("PYTHONSTARTUP", Path.join(hostile, "sitecustomize.py"))

    result =
      File.cd!(cwd, fn -> ReadFormats.read("doc.pdf", %{}, nil, cwd, pdf_python: python) end)

    assert {:ok, %AgentToolResult{content: [%TextContent{text: text}]} = result} = result
    assert result.details.backend == :python
    assert text =~ "Fixture alpha"
    assert text =~ "Fixture beta"
    refute File.exists?(marker)
  end

  test "image previews never execute project sips, directly or via external symlinks", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(cwd, ".git"))
    marker = install_project_tools(cwd, tmp_dir, ["sips"])
    File.write!(Path.join(cwd, "pixel.png"), "\x89PNG\r\n\x1A\n")

    File.cd!(cwd, fn ->
      assert {:error, _} = ReadFormats.image_backend(cwd)
      ReadFormats.read("pixel.png", %{}, nil, cwd, [])
      Read.execute("img", %{"path" => Path.join(cwd, "pixel.png")}, nil, nil, cwd, [])
    end)

    refute File.exists?(marker)
  end

  test "ast_grep discovery never executes project ast-grep/sg, directly or via symlinks", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(cwd, ".git"))
    marker = install_project_tools(cwd, tmp_dir, ["ast-grep", "sg"])
    File.write!(Path.join(cwd, "code.ts"), "call();")

    File.cd!(cwd, fn ->
      assert {:error, _} = AstGrep.availability(cwd)

      assert {:error, _} =
               AstGrep.tool(cwd).execute.(
                 "ast",
                 %{"action" => "search", "pattern" => "call()"},
                 nil,
                 nil
               )
    end)

    refute File.exists?(marker)
  end

  # Project copies of `names` print an ast-grep-like version and record runs.
  # PATH holds relative entries, the project bin, and an external directory of
  # symlinks (file and directory links) whose targets lie inside the project.
  defp install_project_tools(cwd, tmp_dir, names) do
    marker = Path.join(tmp_dir, "project-tool-executed")
    bin = Path.join(cwd, ".lemon/bin")
    File.mkdir_p!(bin)
    external = Path.join(System.tmp_dir!(), "lemon-ext-#{System.unique_integer([:positive])}")
    File.mkdir_p!(external)
    on_exit(fn -> File.rm_rf!(external) end)

    for name <- names do
      script = Path.join(bin, name)
      File.write!(script, "#!/bin/sh\necho ran >> \"#{marker}\"\necho 'ast-grep 0.39.0'\n")
      File.chmod!(script, 0o700)
      File.ln_s!(script, Path.join(cwd, name))
      File.ln_s!(script, Path.join(external, name))
    end

    directory_link =
      Path.join(System.tmp_dir!(), "lemon-dirlink-#{System.unique_integer([:positive])}")

    File.ln_s!(bin, directory_link)
    on_exit(fn -> File.rm(directory_link) end)
    isolate_path(tmp_dir, ["", ".", ".lemon/bin", cwd, bin, external, directory_link])
    marker
  end

  defp put_env(name, value) do
    original = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end)
  end

  defp install_sentinel(directory) do
    interpreter = Path.join(directory, ".lemon/read-formats-venv/bin/python3")
    marker = Path.join(directory, "pdf-interpreter-executed")
    File.mkdir_p!(Path.dirname(interpreter))

    File.write!(interpreter, """
    #!/bin/sh
    printf 'executed\\n' >> "#{marker}"
    echo pypdf
    """)

    File.chmod!(interpreter, 0o700)
    marker
  end

  defp isolate_path(directory, entries) do
    original = System.get_env("PATH")
    empty = Path.join(directory, "empty-path")
    File.mkdir_p!(empty)
    System.put_env("PATH", Enum.join(entries ++ [empty], ":"))

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)
  end

  # Minimal valid PDF with one text line per page (shared shape with ReadFormatsTest).
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
