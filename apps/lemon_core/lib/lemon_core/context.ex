defmodule LemonCore.Context do
  @moduledoc """
  Canonical, client-independent context-reference preview and resolution.

  Supported references are `@file:<path>`, `@folder:<path>`, `@git-diff`
  (optionally `:staged` or `:<safe-revision>`), `@url:<http(s)-url>`, and
  `@session:<session-key>`. Local references are confined to `:root`, reject
  traversal and symlinks, and never use a shell. Document bytes are delegated
  to `LemonCore.Context.Document`, which sniffs PDF, DOCX, XLSX, PPTX, ipynb,
  and plain text.

  `preview/2` performs the same bounded selection as `resolve/2` but removes
  selected text. Every response includes the effective budget, selected byte
  and item counts, redaction state, and structured omissions.
  """

  alias LemonCore.Context.{Document, URLFetcher}
  alias LemonCore.SessionLifecycle

  @version 1
  @default_max_output_bytes 120_000
  @default_max_input_bytes 8_000_000
  @default_max_items 200
  @default_max_depth 6
  @default_max_pages 80
  @default_timeout_ms 15_000
  @max_timeout_ms 60_000
  @safe_git_ref ~r/\A[0-9A-Za-z][0-9A-Za-z._\/~^{}-]{0,127}\z/

  @type response :: %{
          version: pos_integer(),
          mode: :preview | :resolve,
          budget: map(),
          sources: [map()],
          selected_text: String.t() | nil,
          summary: map(),
          omissions: [map()],
          redacted: true
        }

  @doc "Resolve references and return selected, redacted text under one budget."
  @spec resolve([String.t()] | String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def resolve(references, opts \\ []), do: run(:resolve, references, opts)

  @doc "Return exact selection metadata without returning the selected text."
  @spec preview([String.t()] | String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def preview(references, opts \\ []), do: run(:preview, references, opts)

  defp run(mode, references, opts) do
    refs = references |> List.wrap() |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    budget = budget(opts)

    cond do
      refs == [] ->
        {:error, :references_required}

      length(refs) > budget.max_items ->
        {:error, {:reference_limit, length(refs), budget.max_items}}

      true ->
        task = Task.async(fn -> safe_resolve(mode, refs, opts, budget) end)

        case Task.yield(task, budget.timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          {:exit, _reason} -> {:error, :resolution_failed}
          nil -> {:error, :timeout}
        end
    end
  end

  defp safe_resolve(mode, refs, opts, budget) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with :ok <- safe_root(root) do
      do_safe_resolve(mode, refs, opts, budget, root)
    end
  rescue
    _ -> {:error, :resolution_failed}
  catch
    _, _ -> {:error, :resolution_failed}
  end

  defp do_safe_resolve(mode, refs, opts, budget, root) do
    {resolved, omissions} =
      refs
      |> Enum.map(&resolve_reference(&1, root, opts, budget))
      |> Enum.reduce({[], []}, fn
        {:ok, source}, {sources, omitted} -> {[source | sources], omitted}
        {:omit, omission}, {sources, omitted} -> {sources, [omission | omitted]}
      end)

    sources = Enum.reverse(resolved)
    omissions = Enum.reverse(omissions)

    {sources, selected_text, budget_omissions} =
      select_sources(sources, budget.max_output_bytes, mode)

    all_omissions = omissions ++ budget_omissions ++ Enum.flat_map(sources, & &1.omissions)

    {:ok,
     %{
       version: @version,
       mode: mode,
       budget: budget,
       sources: sources,
       selected_text: if(mode == :resolve, do: selected_text, else: nil),
       summary: %{
         requested_references: length(refs),
         selected_sources: length(sources),
         selected_items: Enum.sum(Enum.map(sources, & &1.selected_items)),
         selected_bytes: byte_size(selected_text),
         omitted_count: length(all_omissions),
         redaction_count: Enum.sum(Enum.map(sources, & &1.redaction_count))
       },
       omissions: all_omissions,
       redacted: true
     }}
  end

  defp resolve_reference(reference, root, opts, budget) do
    trimmed = String.trim(reference)

    case parse_reference(trimmed) do
      {:file, path} -> resolve_file(trimmed, path, root, budget)
      {:folder, path} -> resolve_folder(trimmed, path, root, budget)
      {:git_diff, selector} -> resolve_git_diff(trimmed, selector, root, budget)
      {:url, url} -> resolve_url(trimmed, url, opts, budget)
      {:session, key} -> resolve_session(trimmed, key, opts, budget)
      :error -> omit(trimmed, "invalid_reference")
    end
  end

  defp parse_reference("@git-diff"), do: {:git_diff, nil}
  defp parse_reference("@git-diff:" <> selector), do: {:git_diff, selector}
  defp parse_reference("@file:" <> path) when path != "", do: {:file, path}
  defp parse_reference("@folder:" <> path) when path != "", do: {:folder, path}
  defp parse_reference("@url:" <> url) when url != "", do: {:url, url}
  defp parse_reference("@session:" <> key) when key != "", do: {:session, key}
  defp parse_reference(_), do: :error

  defp resolve_file(reference, raw_path, root, budget) do
    with {:ok, path, label} <- safe_local_path(raw_path, root),
         {:ok, stat} <- File.stat(path),
         :ok <- regular_file(stat),
         :ok <- under_size(stat.size, budget.max_input_bytes),
         {:ok, binary} <- File.read(path),
         {:ok, extracted} <- Document.extract_binary(binary, document_opts(budget)) do
      source(
        reference,
        "file",
        label,
        extracted.text,
        extracted.selected_items,
        extracted.omitted,
        format: extracted.format,
        input_bytes: extracted.input_bytes
      )
    else
      {:error, reason} -> omit(reference, reason_name(reason))
    end
  end

  defp resolve_folder(reference, raw_path, root, budget) do
    with {:ok, path, label} <- safe_local_path(raw_path, root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, files, scan_omissions} <- folder_files(path, root, budget) do
      {parts, extract_omissions, selected_items} =
        Enum.reduce(files, {[], [], 0}, fn file, {parts, omissions, count} ->
          case resolve_file(reference, file, root, budget) do
            {:ok, item} ->
              part = "## #{item.label}\n#{item.content}"
              {[part | parts], omissions ++ item.omissions, count + item.selected_items}

            {:omit, omission} ->
              {parts, [Map.put(omission, :label, Path.relative_to(file, root)) | omissions],
               count}
          end
        end)

      source(
        reference,
        "folder",
        label,
        parts |> Enum.reverse() |> Enum.join("\n\n"),
        selected_items,
        scan_omissions ++ Enum.reverse(extract_omissions),
        format: :folder
      )
    else
      {:ok, %File.Stat{}} -> omit(reference, "not_directory")
      {:error, reason} -> omit(reference, reason_name(reason))
    end
  end

  defp resolve_git_diff(reference, selector, root, budget) do
    with :ok <- safe_git_selector(selector),
         {args, label} <- git_args(selector),
         {output, 0} <-
           System.cmd("git", ["-C", root, "diff", "--no-ext-diff"] ++ args,
             stderr_to_stdout: true
           ),
         :ok <- under_size(byte_size(output), budget.max_input_bytes) do
      source(reference, "git-diff", label, output, line_count(output), [], format: :diff)
    else
      {:error, reason} -> omit(reference, reason_name(reason))
      {_output, _status} -> omit(reference, "git_diff_failed")
    end
  end

  defp resolve_url(reference, url, opts, budget) do
    fetch_opts =
      opts
      |> Keyword.take([:resolve_fun, :request_fun, :max_redirects])
      |> Keyword.merge(max_input_bytes: budget.max_input_bytes, timeout_ms: budget.timeout_ms)

    with {:ok, binary, metadata} <- URLFetcher.fetch(url, fetch_opts),
         {:ok, extracted} <- Document.extract_binary(binary, document_opts(budget)) do
      label = metadata.final_url

      source(reference, "url", label, extracted.text, extracted.selected_items, extracted.omitted,
        format: extracted.format,
        input_bytes: extracted.input_bytes,
        content_type: metadata.content_type,
        redirects: metadata.redirects
      )
    else
      {:error, reason} -> omit(reference, reason_name(reason))
    end
  end

  defp resolve_session(reference, key, opts, budget) do
    export_fun = Keyword.get(opts, :session_export_fun, &SessionLifecycle.export/2)

    with {:ok, export} <- export_fun.(key, format: :markdown),
         :ok <- under_size(export.bytes, budget.max_input_bytes) do
      source(
        reference,
        "session",
        "session:#{short_hash(key)}",
        export.content,
        export.run_count,
        [],
        format: :markdown,
        input_bytes: export.bytes,
        upstream_omitted_runs: export.omitted_run_count
      )
    else
      {:error, reason} -> omit(reference, reason_name(reason))
    end
  end

  defp source(reference, type, label, content, selected_items, omissions, metadata) do
    {redacted, count} = redact(content)

    {:ok,
     %{
       reference: redact_reference(reference, type),
       type: type,
       label: label,
       content: redacted,
       selected_items: selected_items,
       redaction_count: count,
       omissions:
         Enum.map(omissions, &Map.put_new(&1, :reference, redact_reference(reference, type))),
       metadata: Map.new(metadata)
     }}
  end

  defp select_sources(sources, max_bytes, mode) do
    {selected, parts, omissions, _remaining} =
      Enum.reduce(sources, {[], [], [], max_bytes}, fn source,
                                                       {selected, parts, omissions, remaining} ->
        header = "### #{source.type}: #{source.label}\n"
        wanted = header <> source.content

        cond do
          remaining <= byte_size(header) ->
            omission = %{
              reference: source.reference,
              reason: "output_budget",
              omitted_bytes: byte_size(wanted)
            }

            {selected, parts, omissions ++ [omission], remaining}

          byte_size(wanted) <= remaining ->
            returned = if mode == :preview, do: Map.delete(source, :content), else: source
            {selected ++ [returned], parts ++ [wanted], omissions, remaining - byte_size(wanted)}

          true ->
            allowed = remaining - byte_size(header)
            {piece, _} = take_bytes(source.content, allowed)

            omission = %{
              reference: source.reference,
              reason: "output_budget",
              omitted_bytes: byte_size(source.content) - byte_size(piece)
            }

            trimmed = %{source | content: piece}
            returned = if mode == :preview, do: Map.delete(trimmed, :content), else: trimmed
            {selected ++ [returned], parts ++ [header <> piece], omissions ++ [omission], 0}
        end
      end)

    {selected, Enum.join(parts, "\n\n"), omissions}
  end

  defp folder_files(path, root, budget) do
    walk_folder(path, root, 0, budget, [], [])
    |> case do
      {:ok, files, omissions} ->
        {:ok, Enum.take(files, budget.max_items),
         omissions ++ item_omission(files, budget.max_items)}

      error ->
        error
    end
  end

  defp walk_folder(_path, _root, depth, budget, files, omissions) when depth > budget.max_depth,
    do: {:ok, files, omissions ++ [%{reason: "depth_limit"}]}

  defp walk_folder(path, root, depth, budget, files, omissions) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, files, omissions}, fn name, {:ok, acc, omitted} ->
          if length(acc) >= budget.max_items do
            {:halt, {:ok, acc, omitted ++ [%{reason: "item_limit"}]}}
          else
            child = Path.join(path, name)

            case File.lstat(child) do
              {:ok, %File.Stat{type: :regular}} ->
                {:cont, {:ok, acc ++ [child], omitted}}

              {:ok, %File.Stat{type: :directory}} ->
                {:cont, walk_folder(child, root, depth + 1, budget, acc, omitted)}

              {:ok, %File.Stat{type: :symlink}} ->
                {:cont,
                 {:ok, acc,
                  omitted ++ [%{reason: "symlink", label: Path.relative_to(child, root)}]}}

              {:ok, _} ->
                {:cont,
                 {:ok, acc,
                  omitted ++ [%{reason: "special_file", label: Path.relative_to(child, root)}]}}

              {:error, _} ->
                {:cont,
                 {:ok, acc,
                  omitted ++ [%{reason: "unreadable", label: Path.relative_to(child, root)}]}}
            end
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_local_path(raw, root) do
    path = if Path.type(raw) == :absolute, do: Path.expand(raw), else: Path.expand(raw, root)

    with :ok <- within_root(path, root),
         :ok <- reject_symlink_components(path, root) do
      {:ok, path, Path.relative_to(path, root)}
    end
  end

  defp within_root(path, root) do
    if path == root or String.starts_with?(path, root <> "/"),
      do: :ok,
      else: {:error, :path_traversal}
  end

  defp reject_symlink_components(path, root) do
    relative = Path.relative_to(path, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _} -> {:cont, next}
        {:error, :enoent} -> {:halt, {:error, :not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp safe_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_root}
      {:ok, _} -> {:error, :invalid_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file(%File.Stat{type: :regular}), do: :ok
  defp regular_file(_), do: {:error, :not_regular_file}
  defp under_size(size, max) when size <= max, do: :ok
  defp under_size(size, max), do: {:error, {:input_too_large, size, max}}

  defp safe_git_selector(nil), do: :ok
  defp safe_git_selector("staged"), do: :ok

  defp safe_git_selector(selector),
    do: if(Regex.match?(@safe_git_ref, selector), do: :ok, else: {:error, :invalid_git_ref})

  defp git_args(nil), do: {["--"], "working-tree"}
  defp git_args("staged"), do: {["--cached", "--"], "staged"}
  defp git_args(selector), do: {[selector, "--"], selector}

  defp redact(content) do
    patterns = [
      {~r/-----BEGIN [^-\n]*PRIVATE KEY-----.*?-----END [^-\n]*PRIVATE KEY-----/s,
       "[REDACTED PRIVATE KEY]"},
      {~r/(?i)\b(authorization\s*:\s*bearer)\s+[^\s]+/, "\\1 [REDACTED]"},
      {~r/(?i)\b(api[_-]?key|access[_-]?token|password|secret|token)\b(\s*[:=]\s*)["']?[^\s,"'}]+/,
       "\\1\\2[REDACTED]"}
    ]

    Enum.reduce(patterns, {content, 0}, fn {pattern, replacement}, {text, count} ->
      matches = length(Regex.scan(pattern, text))
      {Regex.replace(pattern, text, replacement), count + matches}
    end)
  end

  defp redact_reference(reference, "url") do
    case parse_reference(reference) do
      {:url, url} ->
        case URI.parse(url) do
          %URI{} = uri ->
            "@url:" <> (%URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string())

          _ ->
            "@url:[invalid]"
        end

      _ ->
        "@url:[invalid]"
    end
  end

  defp redact_reference(reference, "session"), do: "@session:sha256:#{short_hash(reference)}"
  defp redact_reference(reference, _type), do: reference

  defp short_hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp document_opts(budget),
    do: [
      max_input_bytes: budget.max_input_bytes,
      max_output_bytes: budget.max_output_bytes,
      max_items: budget.max_items,
      max_depth: budget.max_depth,
      max_pages: budget.max_pages,
      max_archive_bytes: budget.max_archive_bytes,
      max_archive_ratio: budget.max_archive_ratio
    ]

  defp budget(opts) do
    max_input = bounded(opts[:max_input_bytes], @default_max_input_bytes, 1, 64_000_000)

    %{
      max_output_bytes: bounded(opts[:max_output_bytes], @default_max_output_bytes, 1, 2_000_000),
      max_input_bytes: max_input,
      max_items: bounded(opts[:max_items], @default_max_items, 1, 5_000),
      max_depth: bounded(opts[:max_depth], @default_max_depth, 1, 32),
      max_pages: bounded(opts[:max_pages], @default_max_pages, 1, 1_000),
      timeout_ms: bounded(opts[:timeout_ms], @default_timeout_ms, 1, @max_timeout_ms),
      max_archive_bytes:
        bounded(opts[:max_archive_bytes], min(max_input * 3, 24_000_000), 1, 128_000_000),
      max_archive_ratio: bounded(opts[:max_archive_ratio], 100, 1, 1_000)
    }
  end

  defp bounded(value, _default, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp bounded(_, default, _min, _max), do: default

  defp omit(reference, reason),
    do: {:omit, %{reference: safe_omission_reference(reference), reason: reason}}

  defp safe_omission_reference("@url:" <> url) do
    case URI.parse(url) do
      %URI{} = uri ->
        "@url:" <> (%URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string())

      _ ->
        "@url:[invalid]"
    end
  end

  defp safe_omission_reference("@session:" <> key), do: "@session:sha256:#{short_hash(key)}"
  defp safe_omission_reference(reference), do: reference

  defp item_omission(files, max) when length(files) > max,
    do: [%{reason: "item_limit", omitted_items: length(files) - max}]

  defp item_omission(_, _), do: []
  defp line_count(""), do: 0
  defp line_count(binary), do: length(:binary.matches(binary, "\n")) + 1

  defp take_bytes(binary, max) when byte_size(binary) <= max, do: {binary, false}
  defp take_bytes(_binary, max) when max <= 0, do: {"", true}

  defp take_bytes(binary, max) do
    candidate = binary_part(binary, 0, max)
    {trim_utf8(candidate), true}
  end

  defp trim_utf8(""), do: ""

  defp trim_utf8(binary),
    do:
      if(String.valid?(binary),
        do: binary,
        else: trim_utf8(binary_part(binary, 0, byte_size(binary) - 1))
      )

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name({reason, _, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(_), do: "unavailable"
end
