defmodule CodingAgent.Tools.Write do
  @moduledoc """
  Write file tool for the coding agent.

  Writes content to a file, creating parent directories as needed.
  Creates the file if it doesn't exist, overwrites if it does.

  Content must be valid UTF-8 without NUL bytes; use a binary-aware tool for
  binary data. Local targets reject symlinks and special files by default.
  After validation, local reads, in-place overwrites and exclusive creates
  (including missing parent directories) run descriptor-bound below the
  validated mutation boundary (`FileValidation`), so a directory swapped for
  a symlink after the check is refused rather than followed.

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
  alias CodingAgent.Tools.Conflicts
  alias CodingAgent.Tools.FileFormatHelpers
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.LspDiagnostics
  alias CodingAgent.Tools.LspFormatter
  alias CodingAgent.Tools.PathHelpers
  alias CodingAgent.Tools.Read
  alias CodingAgent.Tools.Task.Messaging
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
              "File path to write (relative paths resolve from the working directory)"
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

  # `local://` resolves one validated name to this session's own scratch
  # directory, which lives in Lemon state (the session spill directory).
  def execute(id, %{"path" => "local://" <> _ = path} = params, signal, update, cwd, opts) do
    with {:ok, resolved} <- InternalUrls.resolve(path, Keyword.put(opts, :cwd, cwd)) do
      execute(
        id,
        Map.put(params, "path", resolved),
        signal,
        update,
        cwd,
        Keyword.merge(opts, acp_client_fs_write_text_file: false, lemon_owned_target: true)
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

  def execute(id, %{"path" => "conflict://" <> reference} = params, signal, update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      Conflicts.replace(reference, Map.get(params, "content"), cwd, opts, fn
        path, content, cwd, opts ->
          execute(
            id,
            Map.merge(params, %{"path" => path, "content" => content}),
            signal,
            update,
            cwd,
            opts
          )
      end)
    end
  end

  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    # Post-write checkers and formatters run under this call's abort signal.
    opts = Keyword.put(opts, :signal, signal)

    # Check for abort at start
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      with {:ok, path} <- get_path(params),
           {:ok, content} <- get_content(params),
           {:ok, format?} <- LspFormatter.option(params, opts),
           {:ok, diagnostics?} <- LspDiagnostics.option(params, opts) do
        path
        |> resolve_path(cwd, opts)
        |> write_file(content, signal, format?, diagnostics?, cwd, opts)
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
        write_file_with_acp(path, content, cwd, opts)
      else
        write_file_local(path, content, signal, format?, diagnostics?, cwd, opts)
      end
    end
  end

  defp write_file_with_acp(path, content, cwd, opts) do
    {sample, old_text} = acp_existing_text(path, cwd, opts)

    with {:ok, content} <- prepare_content(content, sample),
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

  # `{format sample, old text for the result snapshot}`; the local fallback
  # reads the pinned file descriptor-bound and bounded, like a local write.
  defp acp_existing_text(path, cwd, opts) do
    if ACPFileBridge.read_enabled?(opts) do
      case ACPFileBridge.read_text_file(path, nil, nil, opts) do
        {:ok, text} -> {text, text}
        _ -> {:unavailable, :unavailable}
      end
    else
      case existing_file(Path.expand(path), Keyword.put(opts, :mutation_root, cwd)) do
        {:ok, nil} -> {nil, nil}
        {:ok, existing} -> {existing.sample, existing.old_text}
        {:error, _} -> {:unavailable, :unavailable}
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
    mutation_opts = Keyword.put(opts, :mutation_root, cwd)

    with :ok <- FileValidation.check_mutation_target(path, mutation_opts),
         {:ok, existing} <- existing_file(path, mutation_opts),
         {:ok, content} <- prepare_content(content, existing && existing.sample),
         {:ok, checkpoint} <-
           CheckpointGuard.before_mutation([path], cwd, opts, %{
             tool: "write",
             action: "overwrite",
             path: path
           }) do
      baseline = LspDiagnostics.baseline(path, cwd, diagnostics?, opts)

      do_write_file(
        path,
        content,
        existing,
        signal,
        format?,
        diagnostics?,
        baseline,
        cwd,
        opts,
        checkpoint
      )
    end
  rescue
    e ->
      {:error, "Unexpected error: #{Exception.message(e)}"}
  end

  defp do_write_file(
         path,
         content,
         existing,
         signal,
         format?,
         diagnostics?,
         baseline,
         cwd,
         opts,
         checkpoint
       ) do
    mutation_opts = Keyword.put(opts, :mutation_root, cwd)

    with :ok <- if(AbortSignal.aborted?(signal), do: {:error, :aborted}, else: :ok),
         :ok <- write_target(path, content, existing, mutation_opts) do
      byte_count = byte_size(content)

      {final_content, formatted, format_error} =
        LspFormatter.after_write(path, content, format?, cwd, opts)

      FileReadTracker.record(opts, path, final_content)

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
            existing && existing.old_text,
            final_content
          )
          |> maybe_put_format_error(format_error)
          |> maybe_put_diagnostics(diagnostics)
      }
    end
  end

  # Overwrites keep the pinned file (same inode and mode); new files are created
  # exclusively, with any missing parent directories.
  defp write_target(path, content, nil, opts) do
    case FileValidation.create_regular_file(path, content, opts) do
      :ok -> :ok
      {:error, reason} -> write_error(reason, path)
    end
  end

  defp write_target(path, content, %{identity: identity}, _opts) do
    case FileValidation.write_regular_file(path, identity, content) do
      :ok -> :ok
      {:error, reason} -> write_error(reason, path)
    end
  end

  defp write_error(:eexist, path),
    do: {:error, "Failed to write file: #{path} appeared after validation; nothing was written"}

  defp write_error(reason, _path) when is_binary(reason),
    do: {:error, "Failed to write file: #{reason}"}

  defp write_error(reason, path),
    do:
      {:error, "Failed to write file: #{FileValidation.format_file_error(reason, path, "file")}"}

  # The pinned existing file: format detection samples only its first 64 KiB, and
  # its complete text is kept for the result snapshot when it is at most 16 KiB.
  defp existing_file(path, opts) do
    case FileValidation.regular_file_identity(path, opts) do
      {:ok, identity} ->
        case FileValidation.read_regular_file(path, identity, max_bytes: 65_536, prefix: true) do
          {:ok, sample} ->
            old_text = if byte_size(sample) <= 16_384, do: sample, else: :unavailable
            {:ok, %{identity: identity, sample: sample, old_text: old_text}}

          {:error, reason} ->
            existing_error(reason, path)
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        existing_error(reason, path)
    end
  end

  defp existing_error(reason, _path) when is_binary(reason),
    do: {:error, "Failed to read existing file: #{reason}"}

  defp existing_error(reason, _path),
    do: {:error, "Failed to read existing file: #{:file.format_error(reason)}"}

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
