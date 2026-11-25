defmodule CodingAgent.Tools.ReadArchive do
  @moduledoc false

  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias CodingAgent.Tools.{BoundedInflate, ReadFormats, ReadFormatText}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.ImageContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @suffix ~r/\.(?:zip|tar|tar\.gz|tgz)$/i
  @member_path ~r/^(.*?\.(?:zip|tar\.gz|tgz|tar)):(.*)$/i

  def archive?(path), do: Regex.match?(@suffix, path)

  def split_path(path) do
    case Regex.run(@member_path, path, capture: :all_but_first) do
      [archive, member] -> {archive, member}
      _ -> nil
    end
  end

  def read(path, member, params, signal, opts) do
    with :ok <- ReadFormats.check_input(path, opts),
         :ok <- check_abort(signal),
         {:ok, source} <- open_source(path, signal, opts),
         {:ok, entries} <- entries(path, source),
         :ok <- BoundedInflate.check_entries(length(entries), opts),
         :ok <- check_abort(signal) do
      archive_source = source
      source = if member == "", do: path, else: path <> ":" <> member
      entry = Enum.find(entries, &(&1.name == member))
      prefix = String.trim_trailing(member, "/") <> "/"

      cond do
        member == "" ->
          listing(entries, path, source, params, signal, opts)

        entry && entry.type == :regular ->
          read_member(path, archive_source, entries, entry, source, params, signal, opts)

        (entry && entry.type == :directory) ||
            Enum.any?(entries, &String.starts_with?(&1.name, prefix)) ->
          entries
          |> Enum.filter(&String.starts_with?(&1.name, prefix))
          |> listing(path, source, params, signal, opts)

        entry ->
          {:error,
           "Archive member #{source} is #{entry.type}, not a regular file. Links are not followed."}

        true ->
          {:error,
           "Archive member not found: #{source}. Read #{path} to list exact member names."}
      end
    end
  rescue
    error -> {:error, "Cannot read archive #{path}: #{Exception.message(error)}"}
  end

  # ZIP members are inflated straight from the file; a compressed TAR is
  # gunzipped once under :format_max_decoded_bytes so listing and extraction
  # never stream an unbounded decompressed archive.
  defp open_source(path, signal, opts) do
    cond do
      zip?(path) ->
        {:ok, {:file, String.to_charlist(path)}}

      tar_options(path) == [] ->
        {:ok, {:file, String.to_charlist(path)}}

      true ->
        limit = BoundedInflate.max_decoded_bytes(opts)

        with {:ok, bytes} <- File.read(path) do
          case BoundedInflate.gunzip(bytes, limit, signal) do
            {:ok, raw} ->
              {:ok, {:binary, raw}}

            {:error, :too_large} ->
              {:error,
               "Decompressed archive exceeds the #{limit}-byte limit (:format_max_decoded_bytes): #{path}"}

            {:error, :invalid} ->
              {:error, "Cannot read archive #{path}: invalid gzip data"}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  defp entries(path, source) do
    if zip?(path) do
      {:file, name} = source

      case :zip.list_dir(name) do
        {:ok, records} ->
          entries =
            for zip_file(name: name, info: info, offset: offset, comp_size: comp_size) <- records do
              %{
                name: List.to_string(name),
                type: file_info(info, :type),
                size: file_info(info, :size),
                offset: offset,
                comp_size: comp_size
              }
            end

          {:ok, Enum.sort_by(entries, & &1.name)}

        {:error, reason} ->
          {:error, "Cannot list ZIP: #{inspect(reason)}"}
      end
    else
      case :erl_tar.table(tar_source(source), [:verbose]) do
        {:ok, records} ->
          entries =
            Enum.map(records, fn {name, type, size, _mtime, _mode, _uid, _gid} ->
              %{name: List.to_string(name), type: type, size: size}
            end)

          {:ok, Enum.sort_by(entries, & &1.name)}

        {:error, reason} ->
          {:error, "Cannot list TAR: #{inspect(reason)}"}
      end
    end
  end

  defp tar_source({:file, name}), do: name
  defp tar_source({:binary, _} = binary), do: binary

  defp listing(entries, archive, source, params, signal, opts) do
    text =
      if entries == [] do
        "(empty archive directory)"
      else
        Enum.map_join(entries, "\n", fn entry ->
          suffix =
            if entry.type == :directory and not String.ends_with?(entry.name, "/"),
              do: "/",
              else: ""

          "#{entry.name}#{suffix}\t#{entry.type}\t#{entry.size} bytes"
        end)
      end

    ReadFormatText.result(text, source, params, signal, opts, %{
      format: :archive,
      archive_path: archive,
      is_directory: true,
      total_entries: length(entries),
      immutable: true
    })
  end

  defp read_member(path, archive, entries, entry, source, params, signal, opts) do
    max_bytes = Keyword.get(opts, :format_max_member_bytes, 32 * 1024 * 1024)

    cond do
      entry.size > max_bytes ->
        {:error,
         "Member #{source} is #{entry.size} bytes, exceeding the #{max_bytes}-byte decoded-member limit. Use a streaming archive CLI or raise :format_max_member_bytes."}

      Enum.count(entries, &(&1.name == entry.name)) > 1 ->
        {:error, "Archive member #{entry.name} is ambiguous (duplicate entries)"}

      true ->
        with {:ok, bytes} <- extract_member(path, archive, entry, max_bytes, signal),
             :ok <- check_abort(signal) do
          details = %{
            format: :archive_member,
            archive_path: path,
            member: entry.name,
            immutable: true,
            size: byte_size(bytes)
          }

          member_result(bytes, source, params, signal, opts, details)
        end
    end
  end

  defp extract_member(path, {:file, name}, entry, max_bytes, signal) do
    if zip?(path) do
      {:ok, fd} = :file.open(name, [:read, :raw, :binary])

      try do
        pread = &:file.pread(fd, &1, &2)

        case BoundedInflate.zip_member(
               pread,
               entry.offset,
               entry.comp_size,
               entry.size,
               max_bytes,
               signal
             ) do
          {:ok, bytes} ->
            {:ok, bytes}

          {:error, :too_large} ->
            {:error,
             "Decoded member exceeds its declared size or the #{max_bytes}-byte limit: #{path}:#{entry.name}"}

          {:error, reason} when is_atom(reason) ->
            {:error, "Cannot read archive member #{entry.name}: #{reason} entry data"}

          {:error, _} = error ->
            error
        end
      after
        :file.close(fd)
      end
    else
      extract_tar(name, entry)
    end
  end

  defp extract_member(_path, {:binary, _} = binary, entry, _max_bytes, _signal),
    do: extract_tar(binary, entry)

  # TAR header sizes are exact payload lengths, so the declared-size check
  # above already bounds the extracted member.
  defp extract_tar(source, entry) do
    case :erl_tar.extract(source, [:memory, {:files, [String.to_charlist(entry.name)]}]) do
      {:ok, [{_name, bytes}]} when is_binary(bytes) -> {:ok, bytes}
      {:ok, []} -> {:error, "Archive backend did not return member #{entry.name}"}
      {:ok, _} -> {:error, "Archive member #{entry.name} is ambiguous (duplicate entries)"}
      {:error, reason} -> {:error, "Cannot read archive member #{entry.name}: #{inspect(reason)}"}
    end
  end

  defp member_result(bytes, source, params, signal, opts, details) do
    mime =
      case String.downcase(Path.extname(source)) do
        ".png" -> "image/png"
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".gif" -> "image/gif"
        ".webp" -> "image/webp"
        _ -> nil
      end

    cond do
      mime && byte_size(bytes) <= 20 * 1024 * 1024 ->
        {:ok,
         %AgentToolResult{
           content: [%ImageContent{data: Base.encode64(bytes), mime_type: mime}],
           details:
             Map.merge(details, %{
               path: source,
               source_path: source,
               full_source: source,
               mime_type: mime
             })
         }}

      mime ->
        {:error,
         "Image member exceeds the 20 MiB image limit: #{source}. Resize externally before reading."}

      true ->
        case ReadFormatText.result(bytes, source, params, signal, opts, details) do
          {:error, reason} ->
            {:error,
             "#{reason} Full member source: #{source}; use an archive CLI for binary inspection."}

          result ->
            result
        end
    end
  end

  defp zip?(path), do: String.downcase(Path.extname(path)) == ".zip"

  defp tar_options(path) do
    if String.ends_with?(String.downcase(path), [".tar.gz", ".tgz"]), do: [:compressed], else: []
  end
end
