defmodule LemonSkills.Tools.MediaStatus do
  @moduledoc """
  Read-only media job status for model-facing agent loops.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonMedia.MediaJobSupervisor
  alias LemonMedia.MediaJobs

  @default_limit 10

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_status",
      description:
        "Inspect redacted Lemon media job status, recent generated artifacts, cleanup policy, and worker supervisor state.",
      label: "Media Status",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum recent jobs to return."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    limit = normalize_limit(Map.get(params, "limit", @default_limit))
    media_opts = media_opts(cwd, opts)

    payload =
      %{
        "summary" => stringify(MediaJobs.summary(media_opts)),
        "recent" => stringify(MediaJobs.recent(Keyword.put(media_opts, :limit, limit))),
        "worker_status" => stringify(MediaJobSupervisor.status())
      }

    %AgentToolResult{
      content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
      details: payload
    }
  end

  defp media_opts(cwd, opts) do
    [
      project_dir: cwd,
      dir: Keyword.get(opts, :media_jobs_dir),
      artifacts_dir: Keyword.get(opts, :media_artifacts_dir)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(0) |> min(50)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_limit), do: @default_limit

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
