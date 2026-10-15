defmodule LemonSkills.WorkspacePreferences do
  @moduledoc """
  Owning service for assistant workspace USER.md/MEMORY.md preferences.

  Remember and profile management share the same security, size, and mutation
  rules. Operator entries are scope-bound content identities; deletion requires
  an exact fresh whole-file revision, never a redacted-text match.
  """

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonMemory.{Query, Safety}

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

  @max_text_bytes 4_096

  @doc "Hold the same owning lock used by remember throughout a transfer boundary."
  def transfer_locked(workspace_dir, fun), do: locked(workspace_dir, fun)

  @doc "Read complete preference bytes, distinguishing absent files from empty files."
  def transfer_snapshot(workspace_dir, opts \\ []) do
    with :ok <- safe_workspace(workspace_dir) do
      Enum.reduce_while(["USER.md", "MEMORY.md"], {:ok, %{}}, fn name, {:ok, files} ->
        path = Path.join(workspace_dir, name)

        case safe_file(path) do
          :ok ->
            case File.read(path) do
              {:ok, text} ->
                case if(Keyword.get(opts, :screen, true), do: transfer_text(text), else: :ok) do
                  :ok -> {:cont, {:ok, Map.put(files, name, text)}}
                  error -> {:halt, error}
                end

              {:error, :enoent} ->
                {:cont, {:ok, Map.put(files, name, nil)}}

              _ ->
                {:halt, {:error, :memory_unavailable}}
            end

          error ->
            {:halt, error}
        end
      end)
    end
  end

  def transfer_text(nil), do: :ok

  def transfer_text(text) when is_binary(text) and byte_size(text) <= 65_536 do
    cond do
      not String.valid?(text) or String.contains?(text, <<0>>) -> {:error, :invalid_snapshot}
      screen_text(text) != :ok -> {:error, :unsafe_snapshot}
      true -> :ok
    end
  end

  def transfer_text(_), do: {:error, :snapshot_too_large}

  @doc "Stage exact new bytes and old bytes privately before publishing any file."
  def transfer_stage(workspace_dir, files, previous) do
    stage = Path.join(workspace_dir, ".memory-transfer-" <> LemonCore.Id.uuid())

    with :ok <- safe_workspace(workspace_dir),
         :ok <- File.mkdir_p(workspace_dir),
         :ok <- File.mkdir(stage),
         :ok <- File.chmod(stage, 0o700) do
      result =
        Enum.reduce_while(["USER.md", "MEMORY.md"], :ok, fn name, :ok ->
          with :ok <- stage_bytes(Path.join(stage, name <> ".new"), files[name]),
               :ok <- stage_bytes(Path.join(stage, name <> ".old"), previous[name]) do
            {:cont, :ok}
          else
            _ -> {:halt, {:error, :memory_unavailable}}
          end
        end)

      case result do
        :ok ->
          {:ok, %{dir: stage, workspace: workspace_dir, files: files, previous: previous}}

        error ->
          File.rm_rf(stage)
          error
      end
    else
      _ -> {:error, :memory_unavailable}
    end
  end

  def transfer_publish(stage), do: publish_staged(stage, stage.files, ".new")
  def transfer_restore(stage), do: publish_staged(stage, stage.previous, ".old")
  def transfer_cleanup(stage), do: File.rm_rf(stage.dir)

  defp stage_bytes(_path, nil), do: :ok

  defp stage_bytes(path, bytes) do
    with :ok <- File.write(path, bytes, [:binary, :exclusive, :sync]),
         :ok <- File.chmod(path, 0o600),
         do: :ok
  end

  defp publish_staged(stage, files, suffix) do
    Enum.reduce_while(["USER.md", "MEMORY.md"], :ok, fn name, :ok ->
      path = Path.join(stage.workspace, name)

      result =
        with :ok <- safe_workspace(stage.workspace),
             :ok <- safe_file(path) do
          if files[name] == nil do
            case File.rm(path) do
              :ok -> :ok
              {:error, :enoent} -> :ok
              _ -> {:error, :memory_unavailable}
            end
          else
            File.rename(Path.join(stage.dir, name <> suffix), path)
          end
        end

      case result do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :memory_unavailable}}
      end
    end)
  end

  @doc "Apply a remember workspace mutation, preserving the tool result contract."
  def remember(workspace_dir, target, action, params) do
    locked(workspace_dir, fn ->
      with :ok <- safe_workspace(workspace_dir),
           :ok <- safe_file(Path.join(workspace_dir, Map.fetch!(@targets, target).file)) do
        do_execute(workspace_dir, target, action, params)
      else
        {:error, _} -> {:error, "Workspace preferences unavailable"}
      end
    end)
  end

  @doc "Search bounded raw preference entries before returning their redacted projections."
  def list(workspace_dir, query \\ "") do
    locked(workspace_dir, fn ->
      with :ok <- safe_workspace(workspace_dir),
           {:ok, user} <- read_entries(workspace_dir, "user"),
           {:ok, memory} <- read_entries(workspace_dir, "memory") do
        terms = Query.terms(query)

        entries =
          if query == "",
            do: user ++ memory,
            else: Enum.filter(user ++ memory, &(Query.shared_term_count(terms, &1.text) > 0))

        {:ok, Enum.map(entries, & &1.item)}
      end
    end)
  end

  @doc "Save using remember's screening and capacity rules, then return its exact entry."
  def add(workspace_dir, kind, text) when kind in ["user", "memory"] do
    locked(workspace_dir, fn ->
      with :ok <- safe_workspace(workspace_dir),
           {:ok, text} <- operator_text(text),
           :ok <- operator_screen(text),
           {:ok, previous} <- read_entries(workspace_dir, kind) do
        case Enum.find(previous, &(&1.text == text)) do
          nil -> append_preference(workspace_dir, kind, text, previous)
          entry -> {:ok, entry.item}
        end
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, message} -> workspace_error(message)
      end
    end)
  end

  def add(_, _, _), do: {:error, :invalid_kind}

  defp append_preference(_workspace_dir, _kind, _text, previous) when length(previous) >= 200,
    do: {:error, :capacity_exceeded}

  defp append_preference(workspace_dir, kind, text, _previous) do
    spec = @targets[kind]
    path = Path.join(workspace_dir, spec.file)

    with {:ok, content} <- load_or_init(path, kind, spec),
         rendered = "- " <> String.replace(text, "\n", "\n  ") <> "\n",
         updated = append_under_heading(content, spec.heading, rendered),
         %AgentToolResult{} <-
           write_checked(
             path,
             kind,
             spec,
             updated,
             "add",
             %{changed: true, duplicate: false},
             String.length(text)
           ),
         {:ok, entries} <- read_entries(workspace_dir, kind),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.text == text)) do
      {:ok, entry.item}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, message} -> workspace_error(message)
      _ -> {:error, :memory_unavailable}
    end
  end

  @doc "Inspect one scope-bound preference identity."
  def get(workspace_dir, id) do
    with {:ok, entry} <- find_entry(workspace_dir, id), do: {:ok, entry.item}
  end

  @doc "Preview an exact preference and whole-file revision without mutation."
  def preview_delete(workspace_dir, id) do
    with {:ok, entry} <- find_entry(workspace_dir, id) do
      {:ok, %{id: id, revision: entry.revision}}
    end
  end

  @doc "Delete only if the owning file still matches the preview revision."
  def delete(workspace_dir, id, revision) do
    locked(workspace_dir, fn ->
      with {:ok, entry} <- find_entry(workspace_dir, id),
           true <- entry.revision == revision,
           {:ok, content} <- File.read(entry.path),
           true <- digest(content) == revision do
        # Match the captured byte span, never a bounded/redacted display string.
        updated =
          binary_part(content, 0, entry.start) <>
            binary_part(
              content,
              entry.start + entry.length,
              byte_size(content) - entry.start - entry.length
            )

        case File.write(entry.path, updated) do
          :ok -> {:ok, %{"deleted" => true, "id" => id}}
          {:error, _} -> {:error, :memory_unavailable}
        end
      else
        false -> {:error, :stale}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :memory_unavailable}
      end
    end)
  end

  defp find_entry(workspace_dir, id) do
    with :ok <- safe_workspace(workspace_dir),
         kind when kind in ["user", "memory"] <- preference_kind(id),
         {:ok, entries} <- read_entries(workspace_dir, kind),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.item["id"] == id)) do
      {:ok, entry}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp preference_kind("pref_user_" <> _), do: "user"
  defp preference_kind("pref_memory_" <> _), do: "memory"
  defp preference_kind(_), do: nil

  defp read_entries(workspace_dir, kind) do
    path = Path.join(workspace_dir, @targets[kind].file)

    with :ok <- safe_file(path),
         {:ok, stat} <- File.stat(path, time: :posix),
         true <- stat.size <= 65_536,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) <= 65_536 and String.valid?(content) do
      prefix =
        case Regex.run(~r/\A---\r?\n.*?\r?\n---(?:\r?\n|\z)/s, content) do
          [frontmatter] -> byte_size(frontmatter)
          _ -> 0
        end

      body = binary_part(content, prefix, byte_size(content) - prefix)
      revision = digest(content)

      entries =
        Regex.scan(
          ~r/^[-*] [^\n]*(?:\n(?![-*] |\#)[^\n]*)*|^(?!\s*$|\#|[-*] )[^\n]+(?:\n(?!\s*$|\#|[-*] )[^\n]+)*/m,
          body,
          return: :index,
          capture: :first
        )
        |> Enum.take(200)
        |> Enum.map(fn [{start, length}] ->
          raw = binary_part(body, start, length)
          text = preference_text(raw)
          {redacted, _} = Safety.redact_for_operator(text, max_bytes: 2_045)

          id =
            "pref_#{kind}_" <>
              digest(Path.expand(workspace_dir) <> "\0" <> text) <>
              "." <> revision

          %{
            item: %{
              "id" => id,
              "kind" => kind,
              "text" => redacted,
              "source" => "workspace",
              "createdAtMs" => stat.ctime * 1_000,
              "updatedAtMs" => stat.mtime * 1_000
            },
            text: text,
            path: path,
            revision: revision,
            start: prefix + start,
            length: length
          }
        end)
        |> Enum.uniq_by(& &1.item["id"])

      {:ok, entries}
    else
      {:error, :enoent} -> {:ok, []}
      _ -> {:error, :memory_unavailable}
    end
  end

  defp preference_text(raw) do
    trimmed = String.trim(raw)

    if String.starts_with?(trimmed, ["- ", "* "]) do
      trimmed |> String.replace(~r/^[-*] /, "") |> String.replace("\n  ", "\n")
    else
      trimmed
    end
  end

  defp operator_text(text) when is_binary(text) do
    if String.valid?(text) and byte_size(text) <= @max_text_bytes and
         String.trim(text) != "" and not String.contains?(text, <<0>>) do
      {:ok, String.trim(text)}
    else
      {:error, :invalid_text}
    end
  end

  defp operator_text(_), do: {:error, :invalid_text}

  defp operator_screen(text) do
    case screen_text(text) do
      :ok -> :ok
      _ -> {:error, :unsafe_text}
    end
  end

  defp workspace_error(message) when is_binary(message) do
    if String.contains?(message, "would exceed"),
      do: {:error, :capacity_exceeded},
      else: {:error, :memory_unavailable}
  end

  defp locked(workspace_dir, fun),
    do: :global.trans({{__MODULE__, Path.expand(workspace_dir)}, self()}, fun)

  # Refuse preference-file links and profile-home links; the trusted state root
  # may itself be a system alias (for example /tmp on macOS).
  defp safe_workspace(workspace_dir) do
    [workspace_dir, Path.dirname(workspace_dir), Path.dirname(Path.dirname(workspace_dir))]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        _ -> {:halt, {:error, :memory_unavailable}}
      end
    end)
  end

  defp safe_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 65_536 -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :memory_unavailable}
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp do_execute(workspace_dir, target, action, params) do
    spec = Map.fetch!(@targets, target)
    path = Path.join(workspace_dir, spec.file)

    case action do
      "add" ->
        with {:ok, text} <- get_text(params, "text"),
             :ok <- screen_text(text),
             {:ok, content} <- load_or_init(path, target, spec) do
          add_note(path, target, spec, content, text)
        end

      "replace" ->
        with {:ok, old_text} <- get_text(params, "replaces"),
             {:ok, new_text} <- get_text(params, "text"),
             :ok <- screen_text(new_text),
             {:ok, content} <- load_or_init(path, target, spec) do
          replace_note(path, target, spec, content, old_text, new_text)
        end

      "remove" ->
        with {:ok, text} <- get_text(params, "replaces"),
             {:ok, content} <- load_or_init(path, target, spec) do
          remove_note(path, target, spec, content, text)
        end
    end
  end

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

  defp screen_text(text) do
    case Safety.note_refusal_reason(text) do
      :secret ->
        {:error, "Refusing to store secret-looking content in prompt-injected memory"}

      :invisible ->
        {:error, "Refusing to store invisible or bidirectional control characters"}

      :prompt_injection ->
        {:error, "Refusing to store prompt-injection-like content in prompt-injected memory"}

      nil ->
        :ok
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

      write_checked(
        path,
        target,
        spec,
        updated,
        "add",
        %{changed: true, duplicate: false},
        String.length(text)
      )
    end
  end

  defp replace_note(path, target, spec, content, old_text, new_text) do
    mutate_note(path, target, spec, content, old_text, new_text, "replace")
  end

  defp remove_note(path, target, spec, content, text) do
    mutate_note(path, target, spec, content, text, nil, "remove")
  end

  defp mutate_note(path, target, spec, content, selector, text, action) do
    with {:ok, entries} <- read_entries(Path.dirname(path), target),
         {:ok, _, old, patched} <-
           LemonMemory.NoteMatch.resolve(Enum.map(entries, & &1.text), selector, text),
         :ok <- if(patched, do: screen_text(patched), else: :ok) do
      entry = Enum.find(entries, &(&1.text == old))

      replacement =
        if patched, do: "- " <> String.replace(patched, "\n", "\n  ") <> "\n", else: ""

      updated =
        binary_part(content, 0, entry.start) <>
          replacement <>
          binary_part(
            content,
            entry.start + entry.length,
            byte_size(content) - entry.start - entry.length
          )

      write_checked(
        path,
        target,
        spec,
        updated,
        action,
        %{changed: true},
        if(text, do: String.length(text), else: 0)
      )
    else
      {:error, :ambiguous_match} ->
        {:error,
         "replaces is ambiguous; use longer unique text or the exact whole entry, then retry."}

      {:error, :not_found} ->
        {:error, "replaces was not found"}

      error ->
        error
    end
  end

  defp write_checked(path, target, spec, content, action, details, entry_size) do
    content = String.trim_trailing(content) <> "\n"

    if String.length(content) > spec.max_chars do
      previous =
        case File.read(path) do
          {:ok, previous} -> previous
          _ -> ""
        end

      {:error,
       "#{spec.file} at #{String.length(previous)}/#{spec.max_chars} chars; " <>
         "attempted entry #{entry_size} chars " <>
         "would exceed the limit by #{String.length(content) - spec.max_chars} chars. " <>
         "Remove or shorten entries, then retry.\nCurrent entries:\n" <> previous}
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
