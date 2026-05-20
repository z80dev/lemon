defmodule CodingAgent.Tools.Memory do
  @moduledoc """
  Manage compact assistant-home USER.md and MEMORY.md notes.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonCore.MemorySafety

  @targets %{
    "user" => %{
      file: "USER.md",
      heading: "## Context",
      max_chars: 1_375,
      label: "user profile"
    },
    "memory" => %{
      file: "MEMORY.md",
      heading: "## Quick Facts",
      max_chars: 2_200,
      label: "long-term memory"
    }
  }

  @prompt_injection_patterns [
    ~r/ignore (all )?(previous|prior|above) instructions/i,
    ~r/disregard (all )?(previous|prior|above) instructions/i,
    ~r/reveal (the )?(system|developer) prompt/i,
    ~r/system prompt/i,
    ~r/developer message/i,
    ~r{<\|/?(?:system|developer|assistant|user)\|>}i
  ]

  @invisible_chars [
    "\u202A",
    "\u202B",
    "\u202C",
    "\u202D",
    "\u202E",
    "\u2066",
    "\u2067",
    "\u2068",
    "\u2069",
    "\u200B",
    "\u200C",
    "\u200D",
    "\u200E",
    "\u200F",
    "\uFEFF"
  ]
  @max_text_bytes 4_096

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    workspace_dir = Keyword.get(opts, :workspace_dir)

    %AgentTool{
      name: "memory",
      description:
        "Read, add, replace, or remove compact durable notes in assistant-home USER.md or MEMORY.md.",
      label: "Memory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "type" => "string",
            "enum" => ["user", "memory"],
            "description" =>
              "user updates USER.md profile/preferences; memory updates compact MEMORY.md facts/index."
          },
          "action" => %{
            "type" => "string",
            "enum" => ["read", "add", "replace", "remove"],
            "description" => "Memory operation to perform."
          },
          "text" => %{
            "type" => "string",
            "description" => "Text to add or uniquely remove."
          },
          "old_text" => %{
            "type" => "string",
            "description" => "Unique existing text to replace."
          },
          "new_text" => %{
            "type" => "string",
            "description" => "Replacement text for replace."
          }
        },
        "required" => ["target", "action"]
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
           {:ok, target} <- get_target(params),
           {:ok, action} <- get_action(params) do
        do_execute(workspace_dir, target, action, params)
      end
    end
  end

  defp do_execute(workspace_dir, target, action, params) do
    spec = Map.fetch!(@targets, target)
    path = Path.join(workspace_dir, spec.file)

    case action do
      "read" ->
        read_file(path, target, spec)

      "add" ->
        with {:ok, text} <- get_text(params, "text"),
             :ok <- screen_text(text),
             {:ok, content} <- load_or_init(path, target, spec) do
          add_note(path, target, spec, content, text)
        end

      "replace" ->
        with {:ok, old_text} <- get_text(params, "old_text"),
             {:ok, new_text} <- get_text(params, "new_text"),
             :ok <- screen_text(new_text),
             {:ok, content} <- load_or_init(path, target, spec) do
          replace_note(path, target, spec, content, old_text, new_text)
        end

      "remove" ->
        with {:ok, text} <- get_text(params, "text", Map.get(params, "old_text")),
             {:ok, content} <- load_or_init(path, target, spec) do
          remove_note(path, target, spec, content, text)
        end
    end
  end

  defp validate_workspace_dir(workspace_dir) when is_binary(workspace_dir) do
    if String.trim(workspace_dir) == "" do
      {:error, "workspace_dir is required for memory"}
    else
      :ok
    end
  end

  defp validate_workspace_dir(_), do: {:error, "workspace_dir is required for memory"}

  defp get_target(%{"target" => target}) when is_map_key(@targets, target), do: {:ok, target}
  defp get_target(%{"target" => _}), do: {:error, "target must be either user or memory"}
  defp get_target(_), do: {:error, "missing required parameter: target"}

  defp get_action(%{"action" => action}) when action in ["read", "add", "replace", "remove"],
    do: {:ok, action}

  defp get_action(%{"action" => _}), do: {:error, "action must be read, add, replace, or remove"}
  defp get_action(_), do: {:error, "missing required parameter: action"}

  defp get_text(params, key, fallback \\ nil)

  defp get_text(params, key, fallback) do
    value = Map.get(params, key, fallback)

    cond do
      not is_binary(value) ->
        {:error, "#{key} must be a string"}

      String.trim(value) == "" ->
        {:error, "#{key} must be a non-empty string"}

      byte_size(value) > @max_text_bytes ->
        {:error, "#{key} exceeds #{@max_text_bytes} bytes"}

      String.contains?(value, <<0>>) ->
        {:error, "#{key} cannot contain NUL bytes"}

      true ->
        {:ok, String.trim(value)}
    end
  end

  defp screen_text(text) do
    cond do
      MemorySafety.contains_secret?(text) ->
        {:error, "Refusing to store secret-looking content in prompt-injected memory"}

      contains_invisible_char?(text) ->
        {:error, "Refusing to store invisible or bidirectional control characters"}

      Enum.any?(@prompt_injection_patterns, &Regex.match?(&1, text)) ->
        {:error, "Refusing to store prompt-injection-like content in prompt-injected memory"}

      true ->
        :ok
    end
  end

  defp contains_invisible_char?(text) do
    Enum.any?(@invisible_chars, &String.contains?(text, &1))
  end

  defp read_file(path, target, spec) do
    case File.read(path) do
      {:ok, content} ->
        result("#{spec.label} loaded from #{path}", path, target, "read", content, %{
          exists: true
        })

      {:error, :enoent} ->
        result("#{spec.label} file does not exist yet at #{path}", path, target, "read", "", %{
          exists: false
        })

      {:error, reason} ->
        {:error, "Unable to read #{spec.file}: #{reason}"}
    end
  end

  defp add_note(path, target, spec, content, text) do
    if String.contains?(content, text) do
      result("#{spec.file} already contains that note.", path, target, "add", content, %{
        changed: false,
        duplicate: true
      })
    else
      updated = append_under_heading(content, spec.heading, "- #{text}\n")
      write_checked(path, target, spec, updated, "add", %{changed: true, duplicate: false})
    end
  end

  defp replace_note(path, target, spec, content, old_text, new_text) do
    with :ok <- ensure_unique(content, old_text, "old_text") do
      updated = String.replace(content, old_text, new_text)
      write_checked(path, target, spec, updated, "replace", %{changed: true})
    end
  end

  defp remove_note(path, target, spec, content, text) do
    with :ok <- ensure_unique(content, text, "text") do
      updated =
        content
        |> String.replace("- #{text}\n", "")
        |> String.replace(text, "")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim_trailing()
        |> Kernel.<>("\n")

      write_checked(path, target, spec, updated, "remove", %{changed: true})
    end
  end

  defp ensure_unique(content, text, key) do
    count =
      Regex.scan(Regex.compile!(Regex.escape(text)), content)
      |> length()

    case count do
      0 -> {:error, "#{key} was not found"}
      1 -> :ok
      _ -> {:error, "#{key} must match exactly one occurrence"}
    end
  end

  defp write_checked(path, target, spec, content, action, details) do
    content = String.trim_trailing(content) <> "\n"

    if String.length(content) > spec.max_chars do
      {:error,
       "#{spec.file} would exceed #{spec.max_chars} characters; keep compact memory curated"}
    else
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, content) do
        :ok ->
          result(
            "#{spec.file} #{action} complete at #{path}",
            path,
            target,
            action,
            content,
            details
          )

        {:error, reason} ->
          {:error, "Unable to write #{spec.file}: #{reason}"}
      end
    end
  end

  defp result(message, path, target, action, content, details) do
    %AgentToolResult{
      content: [%TextContent{text: message <> "\n\n" <> content}],
      details:
        Map.merge(details, %{
          target: target,
          action: action,
          path: path,
          bytes: byte_size(content),
          chars: String.length(content)
        })
    }
  end

  defp load_or_init(path, target, spec) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:ok, template_for(target, spec)}

      {:error, reason} ->
        {:error, "Unable to read #{spec.file}: #{reason}"}
    end
  end

  defp template_for("user", _spec) do
    """
    ---
    summary: "User profile record"
    ---

    # USER.md - About Your Human

    ## Context
    """
    |> String.trim_trailing()
  end

  defp template_for("memory", _spec) do
    """
    ---
    summary: "Long-term memory (curated)"
    ---

    # MEMORY.md - Long-term memory

    ## Quick Facts
    """
    |> String.trim_trailing()
  end

  defp append_under_heading(content, heading, addition) do
    content = String.trim_trailing(content)

    if String.contains?(content, heading) do
      content <> "\n\n" <> addition
    else
      content <> "\n\n" <> heading <> "\n\n" <> addition
    end
  end
end
