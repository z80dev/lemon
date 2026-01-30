defmodule CodingAgent.Tools.Glob do
  @moduledoc """
  Glob tool for the coding agent.

  Finds files matching a glob pattern within a directory.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @default_max_results 100

  @doc """
  Returns the glob tool definition.

  ## Options

  - `:max_results` - Maximum results to return (default: 100)
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "glob",
      description: "Find files matching a glob pattern.",
      label: "Glob Files",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to match files"
          },
          "path" => %{
            "type" => "string",
            "description" => "Directory to search in (relative to cwd or absolute)"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return"
          }
        },
        "required" => ["pattern"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, cwd, opts)
    end
  end

  defp do_execute(params, cwd, opts) do
    pattern = Map.get(params, "pattern", "")
    path = Map.get(params, "path")
    max_results = Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    if pattern == "" do
      {:error, "Pattern is required"}
    else
      base_dir = resolve_path(path || cwd, cwd)

      glob_pattern =
        if Path.type(pattern) == :absolute do
          pattern
        else
          Path.join(base_dir, pattern)
        end

      matches =
        Path.wildcard(glob_pattern)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&{&1, file_mtime(&1)})
        |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)

      {entries, truncated} =
        if length(matches) > max_results do
          {Enum.take(matches, max_results), true}
        else
          {matches, false}
        end

      output_lines =
        case entries do
          [] ->
            ["No files found"]

          _ ->
            files = Enum.map(entries, fn {path, _mtime} -> path end)

            if truncated do
              files ++ ["", "(Results are truncated. Consider using a more specific pattern.)"]
            else
              files
            end
        end

      %AgentToolResult{
        content: [%TextContent{text: Enum.join(output_lines, "\n")}],
        details: %{
          count: length(entries),
          truncated: truncated,
          base_path: base_dir
        }
      }
    end
  end

  defp resolve_path(path, cwd) do
    expanded = expand_home(path)

    if Path.type(expanded) == :absolute do
      expanded
    else
      Path.join(cwd, expanded) |> Path.expand()
    end
  end

  defp expand_home("~" <> rest), do: Path.expand("~") <> rest
  defp expand_home(path), do: path

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        case mtime do
          {{_, _, _}, {_, _, _}} = dt -> :calendar.datetime_to_gregorian_seconds(dt)
          %NaiveDateTime{} = ndt -> NaiveDateTime.to_gregorian_seconds(ndt)
          _ -> 0
        end

      _ ->
        0
    end
  end
end
