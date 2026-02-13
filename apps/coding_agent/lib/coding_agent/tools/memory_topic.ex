defmodule CodingAgent.Tools.MemoryTopic do
  @moduledoc """
  Scaffold topic memory files from `memory/topics/TEMPLATE.md`.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @template_relative_path Path.join(["memory", "topics", "TEMPLATE.md"])

  @default_template """
  ---
  summary: "Topic memory note template"
  ---

  # Topic: <topic-slug>

  Use this for durable operational memory (local setup, API access patterns, key paths, recurring workflows).

  ## Purpose

  - What this topic helps with.

  ## How

  1. Primary steps to complete the task.
  2. Include exact commands when useful.

  ## Paths / Commands

  - Important file paths.
  - Frequently used commands.

  ## Gotchas

  - Known failure modes.
  - What to check first when it breaks.

  ## Last Verified

  - Date: YYYY-MM-DD
  - Verified by: (who/session)
  """

  @doc """
  Returns the memory topic scaffold tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    workspace_dir = Keyword.get(opts, :workspace_dir)

    %AgentTool{
      name: "memory_topic",
      description:
        "Create a topic memory file in memory/topics/<slug>.md using memory/topics/TEMPLATE.md.",
      label: "Create Memory Topic",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" =>
              "Topic name or slug (example: \"solana-rpc\"). Will be normalized to a slug."
          },
          "overwrite" => %{
            "type" => "boolean",
            "description" => "Overwrite an existing topic file (default: false)."
          }
        },
        "required" => ["topic"]
      },
      execute: &execute(&1, &2, &3, &4, workspace_dir)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, workspace_dir) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with :ok <- validate_workspace_dir(workspace_dir),
           {:ok, topic} <- get_topic(params),
           {:ok, overwrite?} <- get_overwrite(params),
           {:ok, slug} <- build_slug(topic) do
        create_topic_file(workspace_dir, slug, overwrite?)
      end
    end
  end

  defp validate_workspace_dir(workspace_dir) when is_binary(workspace_dir) do
    if String.trim(workspace_dir) == "" do
      {:error, "workspace_dir is required for memory_topic"}
    else
      :ok
    end
  end

  defp validate_workspace_dir(_), do: {:error, "workspace_dir is required for memory_topic"}

  defp get_topic(%{"topic" => topic}) when is_binary(topic) do
    topic = String.trim(topic)

    if topic == "" do
      {:error, "topic must be a non-empty string"}
    else
      {:ok, topic}
    end
  end

  defp get_topic(%{"topic" => _}), do: {:error, "topic must be a string"}
  defp get_topic(_), do: {:error, "missing required parameter: topic"}

  defp get_overwrite(%{"overwrite" => overwrite}) when is_boolean(overwrite), do: {:ok, overwrite}
  defp get_overwrite(%{"overwrite" => _}), do: {:error, "overwrite must be a boolean"}
  defp get_overwrite(_), do: {:ok, false}

  defp build_slug(topic) do
    slug =
      topic
      |> Path.basename()
      |> String.replace_suffix(".md", "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    cond do
      slug == "" ->
        {:error, "topic does not contain any valid slug characters"}

      slug == "template" ->
        {:error, "topic slug 'template' is reserved"}

      true ->
        {:ok, slug}
    end
  end

  defp create_topic_file(workspace_dir, slug, overwrite?) do
    target_relative = Path.join(["memory", "topics", "#{slug}.md"])
    target_path = Path.join(workspace_dir, target_relative)

    if File.exists?(target_path) and not overwrite? do
      %AgentToolResult{
        content: [
          %TextContent{
            text:
              "Topic memory already exists at #{target_path}. Use read/edit to update it, or pass overwrite=true to regenerate from template."
          }
        ],
        details: %{
          created: false,
          overwritten: false,
          slug: slug,
          path: target_path
        }
      }
    else
      with {:ok, template} <- load_template(workspace_dir) do
        existed_before = File.exists?(target_path)
        File.mkdir_p!(Path.dirname(target_path))
        content = String.replace(template, "<topic-slug>", slug)
        File.write!(target_path, content)
        overwritten = existed_before and overwrite?

        %AgentToolResult{
          content: [
            %TextContent{
              text: "Created topic memory file at #{target_path}"
            }
          ],
          details: %{
            created: true,
            overwritten: overwritten,
            slug: slug,
            path: target_path,
            template: Path.join(workspace_dir, @template_relative_path)
          }
        }
      end
    end
  rescue
    e in File.Error ->
      {:error, "Failed to scaffold topic memory file: #{Exception.message(e)}"}

    e ->
      {:error, "Unexpected error while creating topic memory file: #{Exception.message(e)}"}
  end

  defp load_template(workspace_dir) do
    template_path = Path.join(workspace_dir, @template_relative_path)

    case File.read(template_path) do
      {:ok, template} ->
        {:ok, template}

      {:error, :enoent} ->
        {:ok, @default_template}

      {:error, reason} ->
        {:error, "Unable to read topic template #{template_path}: #{reason}"}
    end
  end
end
