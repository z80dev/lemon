defmodule CodingAgent.Tools.ReadFormats do
  @moduledoc """
  Read-only rich-format dispatch for `CodingAgent.Tools.Read`.

  `read/5` returns `{:ok, AgentToolResult}`, `{:error, message}`, or
  `:not_supported` (the caller should continue its ordinary text/image reader).
  Paths are resolved against `cwd`; an existing literal filename always wins
  over archive-member syntax. Call this before rejecting directories or binary
  documents, and apply the caller's ordinary untrusted-file result tagging.
  This module does not attest that a trust transform ran or record edit hashes.

  ## Paths and parameters

  * A directory delegates to `Ls` with hidden entries and metadata enabled.
  * `bundle.zip`, `bundle.tar`, `bundle.tar.gz`, and `bundle.tgz` list entries.
    `bundle.zip:src/main.ex` reads an exact member; `bundle.zip:src/` lists that
    subtree. Members are immutable virtual sources, never extracted onto disk.
    Use `offset`/`limit` for entry or member-text pagination, not member mutation.
  * `.pdf` extracts actual page text. Optional `page` and `page_limit` select
    1-based pages; omitted values read all pages. Scanned pages need OCR, which
    is not performed here. `pdf_backend/2` reports availability. Backends are
    discovered in order: pdftotext, mutool, Python pypdf/PyMuPDF, using only
    absolute operator PATH entries outside the project and ancestor `.lemon`
    trees (see `ReadFormatCommand.system_executable/2`). `:pdf_python` is an
    explicit operator (constructor) trust grant for a Python interpreter;
    project `.lemon/read-formats-venv` interpreters are never auto-discovered.
    Python always runs isolated (`-I`).
  * `.ipynb` renders indexed markdown/code/raw cells, execution counts, textual
    outputs and errors. `cell` and `cell_limit` select 1-based cells. Binary MIME
    outputs are summarized by MIME type, not embedded as base64 text.
  * SQLite files (`.db`, `.sqlite`, ...) list tables; `app.db:table`,
    `app.db:table:key`, `app.db:table?limit=&offset=&where=&order=` and
    `app.db?q=SELECT ...` give read-only views (see `ReadSqlite`).
  * Raster images use real dimension inspection/downscaling when `sips` is
    available; `image_backend/1` reports preview availability. Small originals
    fall through to the ordinary reader if no preview backend is available.
  `offset` and `limit` always address lines in the rendered selected source.
  Results include numbered text, continuation metadata and `full_source` pointing
  at the complete original document/member. Long-line previews explicitly retain
  that source reference. `:max_lines` and `:max_bytes` match the ordinary reader
  defaults (2000 and 50 KiB). Input and decoded-member safety ceilings are
  configurable with `:format_max_input_bytes` (128 MiB) and
  `:format_max_member_bytes` (32 MiB). Backend output is capped at 32 MiB and
  subprocesses have bounded execution and cancellation checks.
  """

  alias CodingAgent.Tools.{
    Ls,
    PathHelpers,
    ReadArchive,
    ReadFormatText,
    ReadImage,
    ReadJson,
    ReadNotebook,
    ReadPdf,
    ReadSqlite,
    ReadSvg
  }

  alias LemonCore.CredentialPaths

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @spec read(String.t(), map(), reference() | nil, String.t(), keyword()) ::
          {:ok, AgentToolResult.t()} | :not_supported | {:error, String.t()}
  def read(path, params, signal, cwd, opts) do
    with :ok <- check_abort(signal),
         :ok <- validate_params(path, params) do
      resolved = PathHelpers.resolve_path(path, cwd, opts)

      # Selector suffixes (`?q=`, `:table`, `:member`) hide the backing file's
      # identity from the whole-path check, so the parsed file is checked again.
      cond do
        File.dir?(resolved) ->
          read_directory(resolved, params, signal, cwd, opts)

        File.regular?(resolved) ->
          dispatch_file(resolved, params, signal, cwd, opts)

        json = ReadJson.split_path(resolved) ->
          {file, query} = json

          with :ok <- CredentialPaths.check_read(file),
               do: ReadJson.read(file, query, resolved, params, signal, opts)

        sqlite = ReadSqlite.split_path(resolved) ->
          {db, sub_path, query} = sqlite

          with :ok <- CredentialPaths.check_read(db),
               do: ReadSqlite.read(db, sub_path, query, params, signal, opts)

        true ->
          case ReadArchive.split_path(resolved) do
            {archive, member} ->
              with :ok <- CredentialPaths.check_read(archive),
                   do: ReadArchive.read(archive, member, params, signal, opts)

            nil ->
              :not_supported
          end
      end
    end
  end

  @doc "Reports the available real PDF text backend, or an actionable error."
  defdelegate pdf_backend(cwd, opts \\ []), to: ReadPdf, as: :backend

  @doc "Reports availability of actual image dimension inspection/downscaling."
  defdelegate image_backend(cwd), to: ReadImage, as: :backend

  @doc false
  # Every rich reader opens its source after this check.
  def check_input(path, opts) do
    max_bytes = Keyword.get(opts, :format_max_input_bytes, 128 * 1024 * 1024)

    with :ok <- CredentialPaths.check_read(path) do
      check_input_stat(path, max_bytes)
    end
  end

  defp check_input_stat(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= max_bytes ->
        :ok

      {:ok, %{type: :regular, size: size}} ->
        {:error,
         "Source is #{size} bytes, exceeding the #{max_bytes}-byte rich-read input limit. Select a smaller source or raise :format_max_input_bytes."}

      {:ok, _} ->
        {:error, "Rich reads require a regular file: #{path}"}

      {:error, reason} ->
        {:error, "Cannot read source #{path}: #{reason}"}
    end
  end

  defp dispatch_file(path, params, signal, cwd, opts) do
    cond do
      ReadArchive.archive?(path) ->
        ReadArchive.read(path, "", params, signal, opts)

      String.downcase(Path.extname(path)) == ".ipynb" ->
        ReadNotebook.read(path, params, signal, opts)

      String.downcase(Path.extname(path)) == ".pdf" ->
        ReadPdf.read(path, params, signal, cwd, opts)

      String.downcase(Path.extname(path)) == ".svgz" ->
        ReadSvg.text(path, params, signal, opts)

      ReadImage.supported?(path) ->
        ReadImage.read(path, params, signal, cwd, opts)

      ReadSqlite.database?(path) ->
        ReadSqlite.read(path, "", "", params, signal, opts)

      true ->
        :not_supported
    end
  end

  defp read_directory(path, params, signal, cwd, opts) do
    ls_params = %{
      "path" => path,
      "all" => true,
      "long" => true,
      "max_entries" => Keyword.get(opts, :directory_max_entries, 100_000)
    }

    case Ls.execute("read-directory", ls_params, signal, nil, cwd, opts) do
      %AgentToolResult{content: content, details: details} ->
        text = Enum.map_join(content, "\n", fn %TextContent{text: text} -> text end)

        ReadFormatText.result(
          text,
          path,
          params,
          signal,
          opts,
          Map.merge(details, %{format: :directory, is_directory: true, immutable: true})
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_params(path, params) do
    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, "path must be a non-empty string"}

      not is_map(params) ->
        {:error, "read parameters must be an object"}

      true ->
        Enum.reduce_while(
          ["offset", "limit", "page", "page_limit", "cell", "cell_limit"],
          :ok,
          fn key, :ok ->
            case Map.get(params, key) do
              nil -> {:cont, :ok}
              value when is_integer(value) and value > 0 -> {:cont, :ok}
              _ -> {:halt, {:error, "#{key} must be a positive integer (1-indexed)"}}
            end
          end
        )
    end
  end
end
