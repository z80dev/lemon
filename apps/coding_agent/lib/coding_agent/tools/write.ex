defmodule CodingAgent.Tools.Write do
  @moduledoc """
  Write file tool for the coding agent.

  Writes content to a file, creating parent directories as needed.
  Creates the file if it doesn't exist, overwrites if it does.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @doc """
  Returns the write file tool definition.

  ## Options

    * `:cwd` - The current working directory for resolving relative paths

  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "write",
      description:
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Creates parent directories as needed.",
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
           {:ok, content} <- get_content(params) do
        resolved_path = resolve_path(path, cwd, opts)
        write_file(resolved_path, content, signal)
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

  @doc false
  @spec resolve_path(path :: String.t(), cwd :: String.t(), opts :: keyword()) :: String.t()
  defp resolve_path(path, cwd, opts) do
    path
    |> expand_home()
    |> make_absolute(cwd, opts)
  end

  defp expand_home("~" <> rest) do
    Path.expand("~") <> rest
  end

  defp expand_home(path), do: path

  defp make_absolute(path, cwd, opts) do
    if Path.type(path) == :absolute do
      path
    else
      workspace_dir = Keyword.get(opts, :workspace_dir)

      if prefer_workspace_for_path?(path, workspace_dir) do
        Path.join(workspace_dir, path)
      else
        Path.join(cwd, path)
      end
    end
  end

  defp prefer_workspace_for_path?(path, workspace_dir) do
    is_binary(workspace_dir) and String.trim(workspace_dir) != "" and
      not explicit_relative?(path) and
      (path == "MEMORY.md" or String.starts_with?(path, "memory/") or
         String.starts_with?(path, "memory\\"))
  end

  defp explicit_relative?(path) when is_binary(path) do
    String.starts_with?(path, "./") or String.starts_with?(path, "../") or
      String.starts_with?(path, ".\\") or String.starts_with?(path, "..\\")
  end

  defp write_file(path, content, signal) do
    # Check for abort before write
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      try do
        # Create parent directories
        dir = Path.dirname(path)
        File.mkdir_p!(dir)

        # Write the file
        File.write!(path, content)

        byte_count = byte_size(content)

        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: "Successfully wrote #{byte_count} bytes to #{path}"
            }
          ],
          details: %{
            path: path,
            bytes_written: byte_count
          }
        }
      rescue
        e in File.Error ->
          {:error, "Failed to write file: #{Exception.message(e)}"}

        e ->
          {:error, "Unexpected error: #{Exception.message(e)}"}
      end
    end
  end
end
