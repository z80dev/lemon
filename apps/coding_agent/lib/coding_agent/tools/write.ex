defmodule CodingAgent.Tools.Write do
  @moduledoc """
  Write file tool for the coding agent.

  Writes content to a file, creating parent directories as needed.
  Creates the file if it doesn't exist, overwrites if it does.

  Content must be valid UTF-8 without NUL bytes; use a binary-aware tool for
  binary data. Local targets reject symlinks and special files by default.

  `agent://<task-id-or-name>`, `agent://parent`, and `agent://all` send scoped
  peer messages instead of writing files. Sender identity is session-bound.

  Successful results include complete `oldText`/`newText` snapshots only when
  both are at most 16 KiB and the prior contents are known (`nil` for a new local
  file). Larger or unavailable snapshots are omitted, never truncated.
  """

  alias CodingAgent.FileReadTracker
  alias CodingAgent.InternalUrls
  alias CodingAgent.InternalUrls.ProcessProtocol
  alias CodingAgent.MutationLock
  alias CodingAgent.Tools.ACPFileBridge
  alias CodingAgent.Tools.CheckpointGuard
  alias CodingAgent.Tools.FileFormatHelpers
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.LspDiagnostics
  alias CodingAgent.Tools.LspFormatter
  alias CodingAgent.Tools.PathHelpers
  alias CodingAgent.Tools.Read
  alias CodingAgent.Tools.Task.Messaging
  alias CodingAgent.Tools.WriteArchive
  alias CodingAgent.Tools.WriteSqlite
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @doc """
  Returns the write file tool definition.

  ## Options

    * `:cwd` - The current working directory for resolving relative paths

  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    format_default = Keyword.get(opts, :format, false)

    %AgentTool{
      name: "write",
      description:
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Creates parent directories as needed. An agent://<task-id-or-name>, agent://parent, or agent://all path sends a scoped peer message instead of touching the filesystem." <>
          if(format_default,
            do: " Can optionally format supported files after writing.",
            else: ""
          ),
      label: "Write File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "File path, archive.zip:inner/path (also TAR/tgz), db.sqlite:table to insert JSON, or db.sqlite:table:key to update (empty content deletes)"
          },
          "content" => %{
            "type" => "string",
            "description" => "The content to write to the file"
          },
          "format" => %{
            "type" => "boolean",
            "default" => format_default,
            "description" =>
              "Whether to auto-format the file after writing (if a formatter is available for the file extension)"
          },
          "diagnostics" => %{
            "type" => "boolean",
            "default" => Keyword.get(opts, :diagnostics, false),
            "description" =>
              "Whether to run language diagnostics after writing and report newly introduced issues"
          }
        },
        "required" => ["path", "content"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the write file tool.

  ## Parameters

    * `tool_call_id` - Unique identifier for this tool invocation
    * `params` - Map with "path" and "content" keys
    * `signal` - Abort signal reference for cancellation (can be nil)
    * `on_update` - Callback for streaming partial results (unused for write)
    * `cwd` - Current working directory for resolving relative paths
    * `opts` - Checkpoint, diagnostics, formatting, ACP, and trusted-symlink options

  ## Returns

    * `AgentToolResult.t()` - Success result with bytes written
    * `{:error, term()}` - Error if operation failed or was aborted

  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_id, %{"path" => "proc://" <> _ = path} = params, signal, _update, cwd, opts) do
    if AbortSignal.aborted?(signal),
      do: {:error, :aborted},
      else: ProcessProtocol.write(path, params, signal, cwd, opts)
  end

  def execute(id, %{"path" => "local://" <> _ = path} = params, signal, update, cwd, opts) do
    with {:ok, resolved} <- InternalUrls.resolve(path, Keyword.put(opts, :cwd, cwd)) do
      execute(
        id,
        Map.put(params, "path", resolved),
        signal,
        update,
        cwd,
        Keyword.put(opts, :acp_client_fs_write_text_file, false)
      )
    end
  end

  def execute(
        _tool_call_id,
        %{"path" => "agent://" <> _ = path} = params,
        signal,
        _on_update,
        _cwd,
        opts
      ) do
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      case get_content(params) do
        {:ok, content} -> Messaging.send(path, content, opts)
        error -> error
      end
    end
  end

  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    # Check for abort at start
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      with {:ok, path} <- get_path(params),
           {:ok, content} <- get_content(params),
           {:ok, format?} <- LspFormatter.option(params, opts),
           {:ok, diagnostics?} <- LspDiagnostics.option(params, opts) do
        resolved_path = resolve_path(path, cwd, opts)

        cond do
          archive = WriteArchive.target(resolved_path) ->
            WriteArchive.write(archive, content, signal, cwd, opts)

          sqlite = WriteSqlite.target(resolved_path) ->
            WriteSqlite.write(sqlite, content, signal, cwd, opts)

          true ->
            write_file(resolved_path, content, signal, format?, diagnostics?, cwd, opts)
        end
      end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_path(%{"path" => path}) when is_binary(path) and byte_size(path) > 0 do
    {:ok, path}
  end

  defp get_path(%{"path" => _}), do: {:error, "path must be a non-empty string"}
  defp get_path(_), do: {:error, "missing required parameter: path"}

  defp get_content(%{"content" => content}) when is_binary(content) do
    case FileValidation.check_text_content(content, "content") do
      :ok -> {:ok, content}
      error -> error
    end
  end

  defp get_content(%{"content" => _}), do: {:error, "content must be a string"}
  defp get_content(_), do: {:error, "missing required parameter: content"}

  @doc false
  @spec resolve_path(path :: String.t(), cwd :: String.t(), opts :: keyword()) :: String.t()
  defp resolve_path(path, cwd, opts) do
    PathHelpers.resolve_path(path, cwd, Keyword.put(opts, :expand, false))
  end

  defp write_file(path, content, signal, format?, diagnostics?, cwd, opts) do
    # Check for abort before write
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      if ACPFileBridge.write_enabled?(opts) do
        write_file_with_acp(path, content, opts)
      else
        write_file_local(path, content, signal, format?, diagnostics?, cwd, opts)
      end
    end
  end

  defp write_file_with_acp(path, content, opts) do
    old_text =
      if ACPFileBridge.read_enabled?(opts) do
        case ACPFileBridge.read_text_file(path, nil, nil, opts) do
          {:ok, text} -> text
          _ -> :unavailable
        end
      else
        case File.read(path) do
          {:ok, text} -> text
          {:error, :enoent} -> nil
          _ -> :unavailable
        end
      end

    with {:ok, content} <- prepare_content(content, old_text),
         result <- ACPFileBridge.write_text_file(path, content, opts) do
      case result do
        :ok ->
          byte_count = byte_size(content)

          %AgentToolResult{
            content: [
              %TextContent{
                type: :text,
                text: success_message(path, byte_count, false)
              }
            ],
            details:
              %{path: path, bytes_written: byte_count, formatted: false, acp_client: true}
              |> FileValidation.put_text_snapshots(path, old_text, content)
          }

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp write_file_local(path, content, signal, format?, diagnostics?, cwd, opts) do
    path = Path.expand(path)

    MutationLock.with_lock(MutationLock.path_key(path), fn ->
      write_file_local_locked(path, content, signal, format?, diagnostics?, cwd, opts)
    end)
  end

  defp write_file_local_locked(path, content, signal, format?, diagnostics?, cwd, opts) do
    with :ok <-
           FileValidation.check_mutation_target(path, Keyword.put(opts, :mutation_root, cwd)),
         {:ok, existing} <- existing_content(path),
         {:ok, content} <- prepare_content(content, existing),
         {:ok, checkpoint} <-
           CheckpointGuard.before_mutation([path], cwd, opts, %{
             tool: "write",
             action: "overwrite",
             path: path
           }) do
      baseline = LspDiagnostics.baseline(path, cwd, diagnostics?, opts)
      old_text = read_bounded_snapshot(path)

      do_write_file(
        path,
        content,
        signal,
        format?,
        diagnostics?,
        baseline,
        cwd,
        opts,
        checkpoint,
        old_text
      )
    end
  rescue
    e in File.Error ->
      {:error, "Failed to write file: #{Exception.message(e)}"}

    e ->
      {:error, "Unexpected error: #{Exception.message(e)}"}
  end

  defp do_write_file(
         path,
         content,
         signal,
         format?,
         diagnostics?,
         baseline,
         cwd,
         opts,
         checkpoint,
         old_text
       ) do
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      # Create parent directories
      dir = Path.dirname(path)
      File.mkdir_p!(dir)

      # Write the file
      File.write!(path, content)

      byte_count = byte_size(content)
      {formatted, format_error} = LspFormatter.after_write(path, format?, cwd, opts)

      if formatted,
        do: FileReadTracker.refresh(opts, [path]),
        else: FileReadTracker.record(opts, path, content)

      {diagnostics, diagnostics_text} =
        LspDiagnostics.post_edit(path, cwd, baseline, diagnostics?, opts)

      success_text = success_message(path, byte_count, formatted) <> diagnostics_text

      %AgentToolResult{
        content: [
          %TextContent{
            type: :text,
            text: success_text
          }
        ],
        details:
          %{
            path: path,
            bytes_written: byte_count,
            formatted: formatted
          }
          |> CheckpointGuard.put_details(checkpoint)
          |> FileValidation.put_text_snapshots(
            path,
            old_text,
            if(formatted, do: read_bounded_snapshot(path), else: content)
          )
          |> maybe_put_format_error(format_error)
          |> maybe_put_diagnostics(diagnostics)
      }
    end
  end

  defp existing_content(path) do
    result = File.open(path, [:read, :binary], &IO.binread(&1, 65_536))

    case result do
      {:ok, text} when is_binary(text) ->
        {:ok, text}

      {:ok, :eof} ->
        {:ok, ""}

      {:ok, {:error, reason}} ->
        {:error, "Failed to read existing file: #{:file.format_error(reason)}"}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, "Failed to read existing file: #{:file.format_error(reason)}"}
    end
  end

  defp prepare_content(content, old) when is_binary(old) do
    if Read.truncated_output?(content) do
      {:error,
       "content looks like a truncated read output; re-read the omitted range or use edit"}
    else
      {old_bom, old_text} = FileFormatHelpers.strip_bom(old)
      {new_bom, new_text} = FileFormatHelpers.strip_bom(content)
      crlf = length(:binary.matches(old_text, "\r\n"))
      lf = length(:binary.matches(old_text, "\n"))
      ending = if crlf * 2 > lf and not String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
      {:ok, FileFormatHelpers.finalize_content(new_text, ending, new_bom || old_bom)}
    end
  end

  defp prepare_content(content, _old), do: {:ok, content}

  defp read_bounded_snapshot(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        nil

      {:ok, %File.Stat{type: :regular, size: size}} when size <= 16_384 ->
        case File.read(path) do
          {:ok, text} -> text
          _ -> :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp success_message(path, byte_count, true),
    do: "Successfully wrote #{byte_count} bytes to #{path} and formatted the file"

  defp success_message(path, byte_count, false),
    do: "Successfully wrote #{byte_count} bytes to #{path}"

  defp maybe_put_format_error(details, nil), do: details
  defp maybe_put_format_error(details, reason), do: Map.put(details, :format_error, reason)

  defp maybe_put_diagnostics(details, nil), do: details

  defp maybe_put_diagnostics(details, diagnostics),
    do: Map.put(details, :diagnostics, diagnostics)
end
