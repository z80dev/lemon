defmodule CodingAgent.Tools.Write do
  @moduledoc """
  Write file tool for the coding agent.

  Writes content to a file, creating parent directories as needed.
  Creates the file if it doesn't exist, overwrites if it does.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.ACPFileBridge
  alias CodingAgent.Tools.CheckpointGuard
  alias CodingAgent.Tools.LspDiagnostics
  alias CodingAgent.Tools.LspFormatter
  alias CodingAgent.Tools.PathHelpers

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
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Creates parent directories as needed." <>
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
            "description" => "The path to the file to write (relative to cwd or absolute)"
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
    * `opts` - Additional options (currently unused)

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
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    # Check for abort at start
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      with {:ok, path} <- get_path(params),
           {:ok, content} <- get_content(params),
           {:ok, format?} <- get_format(params, opts),
           {:ok, diagnostics?} <- LspDiagnostics.option(params, opts) do
        resolved_path = resolve_path(path, cwd, opts)
        write_file(resolved_path, content, signal, format?, diagnostics?, cwd, opts)
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
    {:ok, content}
  end

  defp get_content(%{"content" => _}), do: {:error, "content must be a string"}
  defp get_content(_), do: {:error, "missing required parameter: content"}

  defp get_format(params, opts) do
    value = Map.get(params, "format", Keyword.get(opts, :format, false))

    case value do
      true -> {:ok, true}
      false -> {:ok, false}
      _ -> {:error, "format must be a boolean"}
    end
  end

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
    case ACPFileBridge.write_text_file(path, content, opts) do
      :ok ->
        byte_count = byte_size(content)

        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: success_message(path, byte_count, false)
            }
          ],
          details: %{path: path, bytes_written: byte_count, formatted: false, acp_client: true}
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_file_local(path, content, signal, format?, diagnostics?, cwd, opts) do
    try do
      with {:ok, checkpoint} <-
             CheckpointGuard.before_mutation([path], cwd, opts, %{
               tool: "write",
               action: "overwrite",
               path: path
             }) do
        baseline = LspDiagnostics.baseline(path, cwd, diagnostics?, opts)

        do_write_file(
          path,
          content,
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
      e in File.Error ->
        {:error, "Failed to write file: #{Exception.message(e)}"}

      e ->
        {:error, "Unexpected error: #{Exception.message(e)}"}
    end
  end

  defp do_write_file(
         path,
         content,
         _signal,
         format?,
         diagnostics?,
         baseline,
         cwd,
         opts,
         checkpoint
       ) do
    # Create parent directories
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    # Write the file
    File.write!(path, content)

    byte_count = byte_size(content)
    {formatted, format_error} = maybe_format_file(path, format?, cwd, opts)

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
        |> maybe_put_format_error(format_error)
        |> maybe_put_diagnostics(diagnostics)
    }
  end

  defp maybe_format_file(_path, false, _cwd, _opts), do: {false, nil}

  defp maybe_format_file(path, true, cwd, opts) do
    timeout_ms = Keyword.get(opts, :format_timeout_ms, 5_000)

    case LspFormatter.format_file(path, cwd: cwd, timeout_ms: timeout_ms) do
      {:ok, :formatted} -> {true, nil}
      {:ok, :unchanged} -> {false, nil}
      {:error, reason} -> {false, to_string(reason)}
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
