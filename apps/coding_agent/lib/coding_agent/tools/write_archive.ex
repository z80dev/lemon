defmodule CodingAgent.Tools.WriteArchive do
  @moduledoc false

  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation, Read, ReadArchive, ReadFormats}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def target(path), do: if(File.exists?(path), do: nil, else: ReadArchive.split_path(path))

  def write({path, member}, content, signal, cwd, opts) do
    path = Path.expand(path)

    MutationLock.with_lock(MutationLock.path_key(path), fn ->
      with :ok <- validate_member(member),
           :ok <-
             FileValidation.check_mutation_target(path, Keyword.put(opts, :mutation_root, cwd)),
           :ok <- check_abort(signal),
           {:ok, bytes} <- rewrite(path, member, content, opts),
           {:ok, checkpoint} <-
             CheckpointGuard.before_mutation([path], cwd, opts, %{
               tool: "write",
               action: "archive_member",
               path: path
             }),
           :ok <- check_abort(signal),
           :ok <- replace(path, bytes) do
        FileReadTracker.refresh(opts, [path])

        %AgentToolResult{
          content: [
            %TextContent{
              text: "Successfully wrote #{byte_size(content)} bytes to #{path}:#{member}"
            }
          ],
          details:
            CheckpointGuard.put_details(
              %{
                path: path,
                member: member,
                bytes_written: byte_size(content),
                format: :archive_member
              },
              checkpoint
            )
        }
      end
    end)
  rescue
    _ -> {:error, "Archive member write failed"}
  end

  defp validate_member(member) do
    cond do
      member == "" or String.ends_with?(member, "/") ->
        {:error, "Archive write must target a file, not a directory"}

      Path.type(member) != :relative or String.contains?(member, "\\") ->
        {:error, "Archive member must be a relative slash-separated path"}

      Enum.any?(String.split(member, "/"), &(&1 in ["..", ".", ""])) ->
        {:error, "Archive member cannot contain empty, '.' or '..' segments"}

      String.contains?(member, <<0>>) ->
        {:error, "Invalid archive member path"}

      true ->
        :ok
    end
  end

  defp rewrite(path, member, content, opts) do
    with :ok <- check_existing(path, opts) do
      if String.downcase(Path.extname(path)) == ".zip",
        do: rewrite_zip(path, member, content),
        else: rewrite_tar(path, member, content)
    end
  end

  defp check_existing(path, opts) do
    if File.exists?(path), do: ReadFormats.check_input(path, opts), else: :ok
  end

  defp rewrite_zip(path, member, content) do
    with {:ok, records} <- zip_records(path),
         :ok <- file_target(records, member),
         :ok <- complete_content(records, member, content),
         {:ok, files} <- zip_files(path, records, member, content),
         {:ok, {_, bytes}} <- :zip.create(~c"archive.zip", files, [:memory]) do
      {:ok, bytes}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Cannot rewrite ZIP archive"}
    end
  end

  defp zip_records(path) do
    if File.exists?(path) do
      case :zip.list_dir(String.to_charlist(path)) do
        {:ok, records} ->
          {:ok,
           for(
             zip_file(name: name, info: info) <- records,
             do: %{name: List.to_string(name), type: file_info(info, :type), info: info}
           )}

        _ ->
          {:error, "Cannot list ZIP archive"}
      end
    else
      {:ok, []}
    end
  end

  defp zip_files(path, records, member, content) do
    extracted =
      if File.exists?(path),
        do: :zip.extract(String.to_charlist(path), [:memory]),
        else: {:ok, []}

    with {:ok, entries} <- extracted do
      data = Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)

      files =
        for record <- records, record.name != member do
          {String.to_charlist(record.name), Map.get(data, record.name, ""), record.info}
        end

      replacement =
        case Enum.find(records, &(&1.name == member)) do
          nil ->
            {String.to_charlist(member), content}

          record ->
            {String.to_charlist(member), content,
             file_info(record.info, size: byte_size(content))}
        end

      {:ok, files ++ [replacement]}
    end
  end

  defp file_target(records, member) do
    cond do
      Enum.count(records, &(&1.name == member)) > 1 ->
        {:error, "Archive member is ambiguous (duplicate entries)"}

      Enum.any?(records, &(&1.name == member and &1.type != :regular)) ->
        {:error, "Archive target is not a regular file"}

      Enum.any?(records, &String.starts_with?(&1.name, member <> "/")) ->
        {:error, "Archive target is a directory"}

      true ->
        :ok
    end
  end

  defp complete_content(records, member, content) do
    if Enum.any?(records, &(&1.name == member)) and Read.truncated_output?(content),
      do:
        {:error,
         "content looks like a truncated read output; re-read the omitted range or use edit"},
      else: :ok
  end

  # Keep every unrelated TAR header, payload, link and extension record verbatim.
  # erl_tar validates the stream and supplies resolved PAX/GNU member names.
  defp rewrite_tar(path, member, content) do
    with {:ok, raw} <- tar_bytes(path),
         {:ok, table} <- :erl_tar.table({:binary, raw}, [:verbose]),
         records =
           Enum.map(table, fn {name, type, size, time, mode, uid, gid} ->
             %{
               name: List.to_string(name),
               type: type,
               size: size,
               time: time,
               mode: mode,
               uid: uid,
               gid: gid
             }
           end),
         :ok <- file_target(records, member),
         :ok <- complete_content(records, member, content),
         {:ok, replacement} <-
           tar_member(member, content, Enum.find(records, &(&1.name == member))),
         {:ok, kept} <- keep_tar(raw, records, member, [], []),
         result =
           IO.iodata_to_binary([Enum.reverse(kept), replacement, :binary.copy(<<0>>, 1024)]) do
      {:ok, if(compressed?(path), do: :zlib.gzip(result), else: result)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Cannot rewrite TAR archive"}
    end
  end

  defp tar_bytes(path) do
    if File.exists?(path) do
      with {:ok, bytes} <- File.read(path) do
        {:ok, if(compressed?(path), do: :zlib.gunzip(bytes), else: bytes)}
      end
    else
      {:ok, :binary.copy(<<0>>, 1024)}
    end
  end

  defp compressed?(path), do: String.ends_with?(String.downcase(path), [".tar.gz", ".tgz"])

  defp tar_member(member, content, record) do
    temp = Path.join(System.tmp_dir!(), "lemon-tar-member-#{System.unique_integer([:positive])}")

    opts =
      if record,
        do: [mtime: record.time, mode: record.mode, uid: record.uid, gid: record.gid],
        else: []

    try do
      with :ok <-
             :erl_tar.create(
               String.to_charlist(temp),
               [{String.to_charlist(member), content}],
               opts
             ),
           {:ok, bytes} <- File.read(temp),
           {:ok, chunks} <- keep_tar(bytes, [%{name: member}], "", [], []) do
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}
      end
    after
      File.rm(temp)
    end
  end

  defp keep_tar(<<0::4096, _::binary>>, [], _member, [], acc), do: {:ok, acc}

  defp keep_tar(<<header::binary-size(512), rest::binary>>, records, member, pending, acc) do
    size_field = binary_part(header, 124, 12)
    size = tar_size(size_field)
    padded = div(size + 511, 512) * 512
    <<payload::binary-size(^padded), rest::binary>> = rest
    chunk = [header, payload]
    type = :binary.at(header, 156)

    cond do
      type in [?x, ?L, ?K] ->
        keep_tar(rest, records, member, [chunk | pending], acc)

      type == ?g ->
        keep_tar(rest, records, member, pending, [chunk | acc])

      true ->
        [record | records] = records
        acc = if record.name == member, do: acc, else: [[Enum.reverse(pending), chunk] | acc]
        keep_tar(rest, records, member, [], acc)
    end
  end

  defp tar_size(<<1::1, size::unsigned-integer-size(95)>>), do: size

  defp tar_size(field) do
    field |> :binary.split(<<0>>) |> hd() |> String.trim() |> String.to_integer(8)
  end

  defp replace(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    temp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      with :ok <- File.write(temp, bytes, [:exclusive]),
           :ok <- preserve_mode(path, temp),
           :ok <- File.rename(temp, path),
           do: :ok
    after
      File.rm(temp)
    end
  end

  defp preserve_mode(path, temp) do
    case File.stat(path) do
      {:ok, stat} -> File.chmod(temp, stat.mode)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
