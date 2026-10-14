defmodule CodingAgent.Tools.ReadPdf do
  @moduledoc false

  alias CodingAgent.Tools.{ReadFormats, ReadFormatText, ReadFormatCommand}

  @missing "PDF text extraction needs pdftotext (Poppler), mutool (MuPDF), or Python with pypdf/PyMuPDF. Install a backend, or create a project-local venv: python3 -m venv .lemon/read-formats-venv && .lemon/read-formats-venv/bin/python3 -m pip install pypdf. Set :pdf_python to its interpreter when reading outside the project."

  @python_probe "import importlib.util; print('pypdf' if importlib.util.find_spec('pypdf') else 'pymupdf' if importlib.util.find_spec('pymupdf') else 'fitz' if importlib.util.find_spec('fitz') else '')"
  @python_read """
  import sys, json, logging, importlib
  logging.disable(logging.CRITICAL)
  name, path, first, count = sys.argv[1:]
  first, count = int(first), int(count)
  if name == 'pypdf':
      from pypdf import PdfReader
      reader = PdfReader(path)
      if reader.is_encrypted and not reader.decrypt(''):
          raise ValueError('PDF is password-protected; decrypt it before reading')
      total = len(reader.pages)
      extract = lambda i: reader.pages[i].extract_text() or ''
  else:
      module = importlib.import_module(name)
      reader = module.open(path)
      if reader.needs_pass:
          raise ValueError('PDF is password-protected; decrypt it before reading')
      total = len(reader)
      extract = lambda i: reader[i].get_text('text')
  if first > total:
      raise ValueError('Requested page %d exceeds document page count %d' % (first, total))
  last = min(total, first + count - 1) if count else total
  pages = [{'page': i + 1, 'text': extract(i)} for i in range(first - 1, last)]
  print(json.dumps({'total_pages': total, 'pages': pages}, ensure_ascii=False))
  """

  def backend(cwd, opts \\ []) do
    cond do
      executable = System.find_executable("pdftotext") ->
        {:ok, %{name: :pdftotext, executable: executable}}

      executable = System.find_executable("mutool") ->
        {:ok, %{name: :mutool, executable: executable}}

      true ->
        python_backend(cwd, opts, nil)
    end
  end

  def read(path, params, signal, cwd, opts) do
    with :ok <- ReadFormats.check_input(path, opts),
         {:ok, backend} <- discover_backend(cwd, opts, signal),
         {:ok, document} <- extract(backend, path, params, signal),
         {:ok, pages} <- validate_pages(document, params) do
      content = render_pages(pages)

      last = pages |> List.last() |> Map.fetch!(:page)
      total = Map.get(document, :total_pages)
      next_page = if total && last < total, do: last + 1

      ReadFormatText.result(content, path, params, signal, opts, %{
        format: :pdf,
        immutable: true,
        backend: backend.name,
        total_pages: total,
        start_page: Map.get(params, "page", 1),
        pages_shown: length(pages),
        next_page: next_page
      })
    end
  end

  @doc """
  Extracts all page text from `path` with the same backends as `read/5`,
  returning `=== Page N ===` sections for callers that render their own output.
  """
  @spec extract_text(String.t(), String.t(), keyword(), reference() | nil) ::
          {:ok, %{text: String.t(), backend: atom(), total_pages: pos_integer() | nil}}
          | {:error, String.t()}
  def extract_text(path, cwd, opts, signal) do
    with :ok <- ReadFormats.check_input(path, opts),
         {:ok, backend} <- discover_backend(cwd, opts, signal),
         {:ok, document} <- extract(backend, path, %{}, signal),
         {:ok, pages} <- validate_pages(document, %{}) do
      {:ok,
       %{
         text: render_pages(pages),
         backend: backend.name,
         total_pages: Map.get(document, :total_pages)
       }}
    end
  end

  defp render_pages(pages) do
    Enum.map_join(pages, "\n\n", fn %{page: page, text: text} ->
      "=== Page #{page} ===\n" <>
        if(String.trim(text) == "",
          do: "[No extractable text on this page; scanned/image-only pages require OCR.]",
          else: String.trim_trailing(text)
        )
    end)
  end

  defp discover_backend(cwd, opts, signal) do
    cond do
      executable = System.find_executable("pdftotext") ->
        {:ok, %{name: :pdftotext, executable: executable}}

      executable = System.find_executable("mutool") ->
        {:ok, %{name: :mutool, executable: executable}}

      true ->
        python_backend(cwd, opts, signal)
    end
  end

  defp python_backend(cwd, opts, signal) do
    candidates =
      [Keyword.get(opts, :pdf_python)] ++
        local_pythons(Path.expand(cwd)) ++ [System.find_executable("python3")]

    candidates = candidates |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.reduce_while(candidates, {:error, @missing}, fn executable, _error ->
      case ReadFormatCommand.run(executable, ["-c", @python_probe], signal,
             timeout_ms: 5000,
             max_bytes: 4096
           ) do
        {:ok, name} ->
          name = String.trim(name)

          if name in ["pypdf", "pymupdf", "fitz"] do
            {:halt, {:ok, %{name: :python, executable: executable, module: name}}}
          else
            {:cont, {:error, @missing}}
          end

        {:error, "Operation aborted"} = error ->
          {:halt, error}

        {:error, _} ->
          {:cont, {:error, @missing}}
      end
    end)
  end

  defp local_pythons(directory) do
    interpreter = Path.join(directory, ".lemon/read-formats-venv/bin/python3")
    here = if File.regular?(interpreter), do: [interpreter], else: []
    parent = Path.dirname(directory)
    if parent == directory, do: here, else: here ++ local_pythons(parent)
  end

  defp extract(%{name: :python} = backend, path, params, signal) do
    args = [
      "-c",
      @python_read,
      backend.module,
      path,
      Integer.to_string(Map.get(params, "page", 1)),
      Integer.to_string(Map.get(params, "page_limit", 0))
    ]

    with {:ok, output} <- ReadFormatCommand.run(backend.executable, args, signal),
         {:ok, %{"total_pages" => total, "pages" => pages}} <- Jason.decode(output) do
      {:ok, %{total_pages: total, pages: Enum.map(pages, &%{page: &1["page"], text: &1["text"]})}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "PDF backend did not return valid page text."}
      error -> error
    end
  end

  defp extract(%{name: :pdftotext} = backend, path, params, signal) do
    first = Map.get(params, "page", 1)
    count = Map.get(params, "page_limit")
    args = ["-layout", "-enc", "UTF-8", "-f", Integer.to_string(first)]
    args = if count, do: args ++ ["-l", Integer.to_string(first + count - 1)], else: args

    with {:ok, text} <- ReadFormatCommand.run(backend.executable, args ++ [path, "-"], signal) do
      {:ok, cli_document(text, first, count)}
    end
  end

  defp extract(%{name: :mutool} = backend, path, params, signal) do
    first = Map.get(params, "page", 1)
    count = Map.get(params, "page_limit")
    range = if count, do: "#{first}-#{first + count - 1}", else: "#{first}-N"

    with {:ok, text} <-
           ReadFormatCommand.run(
             backend.executable,
             ["draw", "-q", "-F", "txt", "-o", "-", path, range],
             signal
           ) do
      {:ok, cli_document(text, first, count)}
    end
  end

  defp cli_document(text, first, count) do
    parts = String.split(text, "\f")
    parts = if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    parts = if parts == [], do: [""], else: parts

    pages =
      parts
      |> Enum.with_index(first)
      |> Enum.map(fn {text, page} -> %{page: page, text: text} end)

    # A bounded CLI page range does not reveal the complete document page count.
    total = if is_nil(count), do: first + length(pages) - 1
    %{pages: pages, total_pages: total}
  end

  defp validate_pages(%{pages: []}, _), do: {:error, "PDF contains no readable pages."}
  defp validate_pages(%{pages: pages}, _), do: {:ok, pages}
end
