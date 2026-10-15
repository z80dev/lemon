defmodule LemonSkills.Tools.Remember do
  @moduledoc """
  Persist, correct, or delete a durable fact through its owning memory service.

  Verified context-owned sessions keep user/memory preferences in the existing
  scoped Store. They never write shared USER.md/MEMORY.md files. A trusted
  runtime shared-memory grant allows only the explicit mutation to create shared
  canonical facts; tool input cannot select or attest that grant. Unproven
  context ownership fails closed. Legacy non-context sessions retain the
  assistant-home file behavior. Project learnings use `LemonMemory.Project`.

  All writes retain secret, invisible-control and prompt-injection screening.

  One call shape per intent:

    * `text` alone appends `- text` under the file's heading (a no-op when the
      file already contains it);
    * `text` with `replaces` swaps one exact existing passage for `text`;
    * `replaces` alone deletes one exact existing passage.

  Its read-side counterpart is `LemonSkills.Tools.Recall`. Registered as a
  builtin tool in `CodingAgent.ToolRegistry`.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonMemory.{ContextScope, Preferences, Project}
  alias LemonSkills.WorkspacePreferences

  @max_text_bytes 4_096

  @doc """
  Returns the `remember` tool definition wired to `execute/5`.

  `cwd` identifies the repository. `opts` carries workspace/agent/session identity
  and flat admitted invocation/memory keys, memory proof and optional trusted
  shared-write grant. Only main sessions write; partial ownership fails closed.
  `:store` selects the existing owner server. Tool params cannot change visibility.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    context = %{
      cwd: cwd,
      workspace_dir: Keyword.get(opts, :workspace_dir),
      agent_id: Keyword.get(opts, :agent_id),
      session_key: Keyword.get(opts, :session_key),
      session_scope: Keyword.get(opts, :session_scope),
      invocation_context_key: Keyword.get(opts, :invocation_context_key),
      memory_context_key: Keyword.get(opts, :memory_context_key),
      memory_context_verified: Keyword.get(opts, :memory_context_verified),
      shared_memory_grant: Keyword.get(opts, :shared_memory_grant, false),
      store_opts: Keyword.take(opts, [:store])
    }

    %AgentTool{
      name: "remember",
      description:
        "Save a durable fact or preference for future sessions in this memory context. " <>
          "The runtime fixes private/shared scope; tool input cannot change it. " <>
          "Target \"user\" records human preferences, \"memory\" records other long-term facts, " <>
          "and \"project\" saves repository build commands, conventions, and decisions. " <>
          "To add a new fact, pass text and omit replaces (or set it to null, never an empty string). " <>
          "To correct or delete a project fact, first recall it with scope \"project\", then copy " <>
          "its exact saved text into replaces. Pass text as well to correct it; omit or null text to delete.",
      label: "Remember",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => ["string", "null"],
            "minLength" => 1,
            "description" =>
              "The fact to save, as one short self-contained sentence. Omit or null only when deleting."
          },
          "target" => %{
            "type" => "string",
            "enum" => ["user", "memory", "project"],
            "description" =>
              "user: human profile/preferences. memory: other personal long-term facts. " <>
                "project: facts specific to this repository. Default memory."
          },
          "replaces" => %{
            "type" => ["string", "null"],
            "minLength" => 1,
            "description" =>
              "Omit or null when adding. For correction/deletion, copy the exact existing saved " <>
                "note or project fact, not a guessed summary. An empty string is invalid."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, context)
    }
  end

  @doc """
  Tool callback invoked by the agent loop: `execute(tool_call_id, params, signal,
  on_update, context)`.

  Reads from `params`:

  - `"text"` - the note to save (add) or the replacement (with `"replaces"`)
  - `"target"` (default `"memory"`) - `"user"`, `"memory"`, or `"project"`
  - `"replaces"` - exact existing text, matched exactly once, to replace or delete

  Text values must be non-empty strings of at most 4096 bytes without NUL bytes;
  saved text is additionally screened against secrets, invisible or
  bidirectional control characters, and prompt-injection patterns.

  Returns `%LemonAgent.Types.AgentToolResult{}` on success: `content` is a single
  `TextContent` with the status and scoped facts or legacy file content. `details`
  includes `target`, `action` (`"add"`, `"replace"`, or `"remove"`), and mutation
  status. Scoped results expose facts and visibility, never private context keys;
  legacy file results additionally include `path`, `bytes`, and `chars`.
  Errors (invalid/missing params, refused content, size overflow, file I/O)
  surface as `{:error, String.t()}` tuples; an aborted signal returns
  `{:error, "Operation aborted"}`.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, context) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with :ok <- validate_workspace_dir(context.workspace_dir),
           :ok <- validate_session_scope(context),
           {:ok, memory_scope} <- ContextScope.scope(context),
           {:ok, target} <- get_target(params),
           {:ok, action} <- get_action(params) do
        cond do
          target == "project" ->
            remember_project(context, action, params)

          memory_scope == :legacy ->
            WorkspacePreferences.remember(context.workspace_dir, target, action, params)

          true ->
            remember_preferences(context, target, action, params)
        end
      else
        {:error, :unproven_context} ->
          {:error, "remember requires a verified private memory context"}

        error ->
          error
      end
    end
  end

  defp validate_session_scope(%{session_scope: :main}), do: :ok
  defp validate_session_scope(_), do: {:error, "remember requires a main session"}

  defp remember_preferences(context, target, action, params) do
    case Preferences.remember(
           context,
           target,
           Map.get(params, "text"),
           Map.get(params, "replaces"),
           context.store_opts
         ) do
      {:ok, result} ->
        visibility = if ContextScope.shared_grant?(context), do: "Shared", else: "Private"

        %AgentToolResult{
          content: [
            %TextContent{
              text:
                "#{visibility} preferences #{if result.changed, do: "updated", else: "unchanged"}.\n\n" <>
                  Enum.map_join(result.facts, "\n", &("- " <> &1))
            }
          ],
          details: %{
            target: target,
            action: action,
            changed: result.changed,
            facts: result.facts,
            memory_scope: String.downcase(visibility)
          }
        }

      {:error, reason} when is_atom(reason) ->
        {:error, "Scoped preferences refused: #{reason}"}

      error ->
        error
    end
  end

  defp remember_project(context, action, params) do
    with {:ok, text} <- optional_text(params, "text"),
         {:ok, replaces} <- optional_text(params, "replaces"),
         {:ok, result} <- Project.remember(context, text, replaces, context.store_opts) do
      %AgentToolResult{
        content: [
          %TextContent{
            text:
              "Project memory #{if result.changed, do: "updated", else: "unchanged"}.\n\n" <>
                Enum.map_join(result.facts, "\n", &("- " <> &1))
          }
        ],
        details: %{
          target: "project",
          action: action,
          changed: result.changed,
          facts: result.facts
        }
      }
    else
      {:error, :not_found} ->
        {:error,
         "No existing project fact matched replaces; nothing was changed. " <>
           "Use recall with scope \"project\" and relevant query keywords, then copy the exact " <>
           "saved fact into replaces. To add a genuinely new fact instead, omit replaces or set it to null."}

      {:error, reason} when is_atom(reason) ->
        {:error, "Project memory refused: #{reason}"}

      error ->
        error
    end
  end

  defp optional_text(params, key) do
    if Map.get(params, key) == nil, do: {:ok, nil}, else: get_text(params, key)
  end

  defp validate_workspace_dir(workspace_dir) when is_binary(workspace_dir) do
    if String.trim(workspace_dir) == "" do
      {:error, "workspace_dir is required for remember"}
    else
      :ok
    end
  end

  defp validate_workspace_dir(_), do: {:error, "workspace_dir is required for remember"}

  defp get_target(params) do
    case Map.get(params, "target", "memory") do
      "project" -> {:ok, "project"}
      target when target in ["user", "memory"] -> {:ok, target}
      _ -> {:error, "target must be user, memory, or project"}
    end
  end

  # The operation follows from which of `text` and `replaces` are present, so
  # the model states what it wants rather than naming an action.
  defp get_action(params) do
    case {present?(Map.get(params, "text")), present?(Map.get(params, "replaces"))} do
      {true, false} -> {:ok, "add"}
      {true, true} -> {:ok, "replace"}
      {false, true} -> {:ok, "remove"}
      {false, false} -> {:error, "remember needs text to save, or replaces to delete a note"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp get_text(params, key) do
    value = Map.get(params, key)

    cond do
      not is_binary(value) ->
        {:error, "#{key} must be a string"}

      key == "replaces" and String.trim(value) == "" ->
        {:error,
         "replaces must be a non-empty string; to add a new fact, omit replaces or set it to null. " <>
           "To correct or delete a fact, use its exact existing saved text."}

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
end
