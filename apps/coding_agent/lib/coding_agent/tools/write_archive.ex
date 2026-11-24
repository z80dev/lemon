defmodule CodingAgent.Tools.WriteArchive do
  @moduledoc false

  # The existing archive is read and atomically replaced through the
  # descriptor-bound FileValidation helpers below the validated mutation
  # boundary; members are rebuilt in memory, never in a shared temp path, and
  # the read tracker records the committed archive bytes.

  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{BoundedInflate, CheckpointGuard, FileValidation, Read, ReadArchive}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def target(path), do: if(File.exists?(path), do: nil, else: ReadArchive.split_path(path))

  def write({path, member}, content, signal, cwd, opts) do
    path = Path.expand(path)
    mutation_opts = Keyword.put(opts, :mutation_root, cwd)

    MutationLock.with_lock(MutationLock.path_key(path), fn ->
      with :ok <- validate_member(member),
           :ok <- FileValidation.check_mutation_target(path, mutation_opts),
           :ok <- check_abort(signal),
           {:ok, identity, existing} <- existing_archive(path, mutation_opts),
           {:ok, bytes} <- rewrite(path, existing, member, content, signal, opts),
           {:ok, checkpoint} <-
             CheckpointGuard.before_mutation([path], cwd, opts, %{
               tool: "write",
               action: "archive_member",
               path: path
             }),
           :ok <- check_abort(signal),
           :ok <- replace(path, identity, bytes, mutation_opts) do
        FileReadTracker.record(opts, path, bytes)

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

  defp existing_archive(path, opts) do
    max_bytes = Keyword.get(opts, :format_max_input_bytes, 128 * 1024 * 1024)

    with {:ok, identity} <- FileValidation.regular_file_identity(path, opts),
         {:ok, bytes} <- FileValidation.read_regular_file(path, identity, max_bytes: max_bytes) do
      {:ok, identity, bytes}
    else
      {:error, :enoent} -> {:ok, nil, nil}
      {:error, reason} -> {:error, archive_error(reason, path)}
    end
  end

  defp replace(path, identity, bytes, opts) do
    case FileValidation.replace_regular_file(path, identity, bytes, opts) do
      :ok -> :ok
      {:error, :eexist} -> {:error, "Archive appeared after validation; nothing was written"}
      {:error, reason} -> {:error, archive_error(reason, path)}
    end
  end

  defp archive_error(reason, _path) when is_binary(reason), do: reason
  defp archive_error(reason, path), do: FileValidation.format_file_error(reason, path, "archive")

  # Unrelated members are decoded through BoundedInflate under one
  # :format_max_decoded_bytes budget; a lying or high-ratio member aborts the
  # write before anything is replaced.
  defp rewrite(path, existing, member, content, signal, opts) do
    if String.downcase(Path.extname(path)) == ".zip",
      do: rewrite_zip(existing, member, content, signal, opts),
      else: rewrite_tar(path, existing, member, content, signal, opts)
  end

  defp rewrite_zip(existing, member, content, signal, opts) do
    with {:ok, records} <- zip_records(existing),
         :ok <- BoundedInflate.check_entries(length(records), opts),
         :ok <- file_target(records, member),
         :ok <- complete_content(records, member, content),
         {:ok, files} <-
           zip_files(
             existing,
             records,
             member,
             content,
             signal,
             BoundedInflate.max_decoded_bytes(opts)
           ),
         {:ok, {_, bytes}} <- :zip.create(~c"archive.zip", files, [:memory]) do
      {:ok, bytes}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Cannot rewrite ZIP archive"}
    end
  end

  defp zip_records(nil), do: {:ok, []}

  defp zip_records(existing) do
    case :zip.list_dir(existing) do
      {:ok, records} ->
        {:ok,
         for(
           zip_file(name: name, info: info, offset: offset, comp_size: comp_size) <- records,
           do: %{
             name: List.to_string(name),
             type: file_info(info, :type),
             info: info,
             offset: offset,
             comp_size: comp_size
           }
         )}

      _ ->
        {:error, "Cannot list ZIP archive"}
    end
  end

  defp zip_files(existing, records, member, content, signal, budget) do
    pread = fn offset, length ->
      if offset + length <= byte_size(existing),
        do: {:ok, binary_part(existing, offset, length)},
        else: :eof
    end

    kept =
      Enum.reduce_while(records, {:ok, [], budget}, fn
        %{name: ^member}, acc ->
          {:cont, acc}

        %{type: :regular} = record, {:ok, files, remaining} ->
          declared = file_info(record.info, :size)

          case BoundedInflate.zip_member(
                 pread,
                 record.offset,
                 record.comp_size,
                 declared,
                 remaining,
                 signal
               ) do
            {:ok, bytes} ->
              file = {String.to_charlist(record.name), bytes, record.info}
              {:cont, {:ok, [file | files], remaining - byte_size(bytes)}}

            {:error, :too_large} ->
              {:halt,
               {:error,
                "Archive members exceed their declared sizes or the #{budget}-byte decoded limit (:format_max_decoded_bytes); nothing was written"}}

            {:error, reason} when is_binary(reason) ->
              {:halt, {:error, reason}}

            {:error, _} ->
              {:halt, {:error, "Cannot decode ZIP member #{record.name}; nothing was written"}}
          end

        record, {:ok, files, remaining} ->
          {:cont, {:ok, [{String.to_charlist(record.name), "", record.info} | files], remaining}}
      end)

    with {:ok, files, _remaining} <- kept do
      replacement =
        case Enum.find(records, &(&1.name == member)) do
          nil ->
            {String.to_charlist(member), content}

          record ->
            {String.to_charlist(member), content,
             file_info(record.info, size: byte_size(content))}
        end

      {:ok, Enum.reverse(files, [replacement])}
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
  defp rewrite_tar(path, existing, member, content, signal, opts) do
    with {:ok, raw} <- tar_bytes(path, existing, signal, BoundedInflate.max_decoded_bytes(opts)),
         {:ok, table} <- :erl_tar.table({:binary, raw}, [:verbose]),
         :ok <- BoundedInflate.check_entries(length(table), opts),
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

  defp tar_bytes(_path, nil, _signal, _limit), do: {:ok, :binary.copy(<<0>>, 1024)}

  defp tar_bytes(path, existing, signal, limit) do
    cond do
      not compressed?(path) ->
        {:ok, existing}

      true ->
        case BoundedInflate.gunzip(existing, limit, signal) do
          {:ok, raw} ->
            {:ok, raw}

          {:error, :too_large} ->
            {:error,
             "Decompressed archive exceeds the #{limit}-byte limit (:format_max_decoded_bytes); nothing was written"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, _} ->
            {:error, "Cannot rewrite TAR archive: invalid gzip data"}
        end
    end
  end

  defp compressed?(path), do: String.ends_with?(String.downcase(path), [".tar.gz", ".tgz"])

  # erl_tar writes the single member to an in-memory file.
  defp tar_member(member, content, record) do
    opts =
      if record,
        do: [mtime: record.time, mode: record.mode, uid: record.uid, gid: record.gid],
        else: []

    {:ok, ram} = :file.open("", [:ram, :read, :write, :binary])

    try do
      with {:ok, tar} <- :erl_tar.init(ram, :write, &ram_tar/2),
           :ok <- :erl_tar.add(tar, content, String.to_charlist(member), opts),
           :ok <- :erl_tar.close(tar),
           {:ok, size} <- :file.position(ram, :eof),
           {:ok, 0} <- :file.position(ram, :bof),
           {:ok, bytes} <- :file.read(ram, size),
           {:ok, chunks} <- keep_tar(bytes, [%{name: member}], "", [], []) do
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}
      end
    after
      :file.close(ram)
    end
  end

  defp ram_tar(:write, {ram, data}), do: :file.write(ram, data)
  defp ram_tar(:position, {ram, position}), do: :file.position(ram, position)
  defp ram_tar(:read2, {ram, size}), do: :file.read(ram, size)
  defp ram_tar(:close, _ram), do: :ok

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
end
