defmodule CodingAgent.Session.Rewind do
  @moduledoc """
  Active-branch rewind with preview-bound, opt-in filesystem restoration.

  Rewind moves the cursor to immediately before a selected user message. The
  abandoned suffix remains in the session tree, but is no longer sent to the
  model. Recorded mutations restore in reverse chronological order, including
  overlapping file and directory snapshots. Confirmation binds the branch revision
  and current tree contents; it expires after five minutes and is single use.
  Arbitrary eval and executing/unknown debug actions remain unrestorable even when
  they fail or are interrupted. Only explicit debug inspection is exempt; shell-only
  partial consent does not cover arbitrary code execution.
  Effect classification unwraps persisted `tool_invoke` targets while matching
  results by the unchanged outer tool name and call ID. Missing bridge identity
  remains unrestorable; bridge result metadata cannot claim a pure target.
  """

  alias CodingAgent.SessionManager
  alias LemonCore.{Checkpoint, Store}

  @confirmation_table :session_rewinds
  @confirmation_ttl_ms 5 * 60 * 1000
  @mutation_tools ~w(write edit patch apply_patch bash)
  @debug_inspection_actions ~w(status sessions output threads stack_trace scopes)
  @max_review_commands 100
  @max_command_chars 2048

  def tree(session, opts \\ []) do
    entries = SessionManager.entries(session)
    active = MapSet.new(SessionManager.get_branch(session), & &1.id)
    parents = MapSet.new(entries, & &1.parent_id)
    labels = SessionManager.labels(session)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 100)

    branches =
      entries
      |> Enum.filter(&(not MapSet.member?(parents, &1.id) or &1.id == session.leaf_id))
      |> Enum.map(&%{"leafId" => &1.id, "active" => &1.id == session.leaf_id})

    nodes =
      entries
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(fn entry ->
        role = entry.message && field(entry.message, :role)
        on_branch = MapSet.member?(active, entry.id)

        %{
          "id" => entry.id,
          "parentId" => entry.parent_id,
          "type" => Atom.to_string(entry.type),
          "role" => if(role, do: to_string(role)),
          "text" => preview(entry),
          "timestamp" => entry.timestamp,
          "isActive" => on_branch,
          "isLeaf" => not MapSet.member?(parents, entry.id),
          "rewindable" => on_branch and role in [:user, "user"],
          "label" => labels |> Map.get(entry.id) |> project_label()
        }
      end)

    %{
      "sessionId" => session.header.id,
      "leafId" => session.leaf_id,
      "entries" => nodes,
      "branches" => branches,
      "totalEntries" => length(entries),
      "offset" => offset,
      "hasMore" => offset + length(nodes) < length(entries)
    }
  end

  @doc """
  Resolve where an active-branch switch to `entry_id` lands. A user message
  lands before itself and returns its text so a client can offer it for
  editing (the same convention as rewind); any other entry becomes the leaf.
  `leaf: nil` means the empty root.
  """
  @spec navigation_target(SessionManager.Session.t(), String.t()) ::
          {:ok, %{leaf: String.t() | nil, prompt: String.t() | nil}} | {:error, :entry_not_found}
  def navigation_target(session, entry_id) do
    case SessionManager.get_entry(session, entry_id) do
      nil ->
        {:error, :entry_not_found}

      %{type: :message, message: message} = entry ->
        if field(message, :role) in [:user, "user"],
          do: {:ok, %{leaf: entry.parent_id, prompt: message_text(message)}},
          else: {:ok, %{leaf: entry.id, prompt: nil}}

      entry ->
        {:ok, %{leaf: entry.id, prompt: nil}}
    end
  end

  @doc false
  def navigation_receipt(session, entry_id, target, summarizing) do
    %{
      "sessionId" => session.header.id,
      "entryId" => entry_id,
      "leafId" => session.leaf_id,
      "prompt" => target.prompt,
      "summarizing" => summarizing
    }
  end

  @doc false
  def label_receipt(session, entry_id) do
    %{
      "sessionId" => session.header.id,
      "entryId" => entry_id,
      "label" => session |> SessionManager.labels() |> Map.get(entry_id) |> project_label()
    }
  end

  @doc """
  Collapse model-owned exploration at an active branch boundary. Unlike operator
  rewind this never restores files and does not require user confirmation.
  The caller binds the boundary to its single-use checkpoint.
  """
  def collapse_context(session, boundary, report, details, retained_messages) do
    if Enum.any?(SessionManager.get_branch(session), &(&1.id == boundary)) do
      from = session.leaf_id

      summary =
        "Checkpoint complete. Continue from these findings; do not rewind again.\n\n" <> report

      manager =
        session
        |> SessionManager.set_leaf_id(boundary)
        |> SessionManager.append_entry(
          SessionManager.SessionEntry.branch_summary(from, summary, details: details)
        )

      {:ok, Enum.reduce(retained_messages, manager, &SessionManager.append_message(&2, &1))}
    else
      {:error, :checkpoint_not_on_active_branch}
    end
  end

  def run(session, entry_id, opts \\ []) do
    if Keyword.get(opts, :allow_partial_restore, false) and
         not Keyword.get(opts, :restore_files, false) do
      {:error, :invalid_partial_restore}
    else
      with {:ok, target, suffix} <- target_suffix(session, entry_id) do
        if Keyword.get(opts, :dry_run, true) do
          preview_rewind(session, target, suffix, opts)
        else
          execute_rewind(session, target, suffix, opts)
        end
      end
    end
  end

  defp preview_rewind(session, target, suffix, opts) do
    restore_files = Keyword.get(opts, :restore_files, false)
    allow_partial = Keyword.get(opts, :allow_partial_restore, false)
    {plan, unavailable, review} = restoration_review(session, suffix)

    with {:ok, fingerprints} <- fingerprints(plan, restore_files) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      confirmation = %{
        token: token,
        revision: revision(session),
        entry_id: target.id,
        restore_files: restore_files,
        allow_partial_restore: allow_partial,
        plan: plan,
        fingerprints: fingerprints,
        unavailable: unavailable,
        review: review,
        expires_at: System.system_time(:millisecond) + @confirmation_ttl_ms
      }

      case Store.put(@confirmation_table, session.header.id, confirmation) do
        :ok ->
          {:ok,
           Map.merge(review, %{
             "sessionId" => session.header.id,
             "entryId" => target.id,
             "confirmationToken" => token,
             "restoreFiles" => restore_files,
             "allowPartialRestore" => allow_partial,
             "prompt" => message_text(target.message),
             "promptContainsNonText" => message_contains_non_text?(target.message),
             "discardedMessages" => Enum.count(suffix, &(&1.type in [:message, :custom_message])),
             "restorePaths" => restore_paths(plan),
             "unrestorableTools" => unavailable
           }), session}

        {:error, _} ->
          {:error, :session_store_unavailable}
      end
    end
  end

  defp execute_rewind(session, target, suffix, opts) do
    token = Keyword.get(opts, :confirmation_token)
    confirmation = Store.get(@confirmation_table, session.header.id)
    restore_files = Keyword.get(opts, :restore_files, false)
    allow_partial = Keyword.get(opts, :allow_partial_restore, false)
    {plan, unavailable, review} = restoration_review(session, suffix)

    cond do
      not is_binary(token) or token == "" ->
        {:error, :confirmation_required}

      not is_map(confirmation) or confirmation.token != token or
        confirmation.expires_at < System.system_time(:millisecond) or
        confirmation.revision != revision(session) or confirmation.entry_id != target.id or
        confirmation.restore_files != restore_files or confirmation.plan != plan or
        Map.get(confirmation, :allow_partial_restore) != allow_partial or
        Map.get(confirmation, :review) != review or confirmation.unavailable != unavailable ->
        {:error, :stale_confirmation}

      restore_files and Enum.any?(unavailable, &(&1 in ["eval", "debug"])) ->
        {:error, :unrestorable_effects}

      restore_files and Enum.any?(unavailable, &(&1 != "bash")) ->
        {:error, :checkpoint_missing}

      restore_files and review["unrestorableCommandCount"] > 0 and not allow_partial ->
        {:error, :unrestorable_effects}

      restore_files and allow_partial and review["unrestorableCommandCount"] > 0 and
          not review["canAllowPartialRestore"] ->
        {:error, :partial_restore_unreviewable}

      true ->
        with {:ok, current} <- fingerprints(plan, restore_files),
             true <- current == confirmation.fingerprints,
             :ok <- Store.compare_and_delete(@confirmation_table, session.header.id, confirmation),
             {:ok, receipt, session} <-
               restore_and_rewind(session, target, if(restore_files, do: plan, else: [])) do
          receipt =
            receipt
            |> Map.merge(review)
            |> Map.merge(%{
              "confirmationToken" => token,
              "restoreFiles" => restore_files,
              "allowPartialRestore" => allow_partial,
              "partialRestore" =>
                restore_files and allow_partial and review["unrestorableCommandCount"] > 0,
              "unrestorableTools" => unavailable
            })

          {:ok, receipt, session}
        else
          false -> {:error, :stale_confirmation}
          {:error, :mismatch} -> {:error, :stale_confirmation}
          {:error, _} = error -> error
        end
    end
  end

  defp restore_and_rewind(session, target, plan) do
    with {:ok, backup} <- backup_current_files(session, plan) do
      try do
        case restore_plan(plan) do
          :ok ->
            session = SessionManager.set_leaf_id(session, target.parent_id)

            {:ok,
             %{
               "sessionId" => session.header.id,
               "entryId" => target.id,
               "prompt" => message_text(target.message),
               "leafId" => session.leaf_id,
               "restoredPaths" => restore_paths(plan)
             }, session}

          {:error, _} ->
            rollback_files(backup)
        end
      rescue
        _ -> rollback_files(backup)
      end
    end
  end

  defp backup_current_files(_session, []), do: {:ok, nil}

  defp backup_current_files(session, plan) do
    case Checkpoint.create_filesystem(session.header.id, restore_paths(plan),
           cwd: session.header.cwd,
           tool: "rewind",
           metadata: %{reason: "rewind_rollback"}
         ) do
      {:ok, checkpoint} -> {:ok, checkpoint.id}
      {:error, _} -> {:error, :restore_failed}
    end
  end

  defp rollback_files(nil), do: {:error, :restore_failed}

  defp rollback_files(backup) do
    case Checkpoint.restore_filesystem(backup) do
      {:ok, _} -> {:error, :restore_failed}
      {:error, _} -> {:error, :restore_rollback_failed}
    end
  end

  defp restore_plan(plan) do
    Enum.reduce_while(plan, :ok, fn item, :ok ->
      case Checkpoint.restore_filesystem(item.checkpoint_id, paths: [item.path]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :restore_failed}}
      end
    end)
  end

  defp target_suffix(session, entry_id) do
    case SessionManager.get_entry(session, entry_id) do
      nil ->
        {:error, :entry_not_found}

      %{type: :message, message: message} = target ->
        if field(message, :role) in [:user, "user"] do
          case Enum.split_while(SessionManager.get_branch(session), &(&1.id != entry_id)) do
            {_, []} -> {:error, :entry_not_on_active_branch}
            {_, suffix} -> {:ok, target, suffix}
          end
        else
          {:error, :not_user_message}
        end

      _ ->
        {:error, :not_user_message}
    end
  end

  defp restoration_review(session, suffix) do
    calls = persisted_calls(suffix)
    index = call_index(calls)
    {plan, unavailable} = restoration_plan(session, suffix, calls, index)
    commands = shell_commands(suffix, calls, index)
    unavailable = if commands == [], do: unavailable, else: Enum.uniq(unavailable ++ ["bash"])
    count = length(commands)

    review = %{
      "unrestorableCommands" =>
        commands |> Enum.take(@max_review_commands) |> Enum.map(& &1.display),
      "unrestorableCommandCount" => count,
      "canAllowPartialRestore" =>
        unavailable == ["bash"] and count > 0 and count <= @max_review_commands and
          Enum.all?(commands, & &1.complete?)
    }

    {plan, unavailable, review}
  end

  defp shell_commands(suffix, invocations, index) do
    calls =
      invocations
      |> Enum.filter(&(&1.name == "bash"))
      |> Enum.map(&{{&1.outer_name, &1.id}, field(&1.arguments, :command)})

    call_ids = MapSet.new(calls, &elem(&1, 0))

    missing =
      Enum.flat_map(suffix, fn entry ->
        message = entry.message

        identity =
          {field(message, :tool_name), field(message, :tool_call_id) || {:result, entry.id}}

        invocation = result_invocation(message, index)

        if field(message, :role) in [:tool_result, "tool_result"] and
             invocation.name == "bash" and not MapSet.member?(call_ids, identity),
           do: [{identity, nil}],
           else: []
      end)

    (calls ++ missing)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {_id, command} -> command_review(command) end)
  end

  defp command_review(command) when is_binary(command) and command != "" do
    text =
      command
      |> LemonCore.Redact.text()
      |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "")

    if String.length(text) <= @max_command_chars,
      do: %{display: text, complete?: true},
      else: %{
        display: String.slice(text, 0, @max_command_chars) <> " [truncated]",
        complete?: false
      }
  end

  defp command_review(_),
    do: %{display: "[shell command unavailable in persisted history]", complete?: false}

  defp restoration_plan(session, suffix, calls, index) do
    mutating_calls = Enum.filter(calls, &mutating_call?/1)

    mutating_ids = MapSet.new(mutating_calls, &{&1.outer_name, &1.id})

    {paths, unavailable} =
      Enum.reduce(suffix, {[], []}, fn entry, {paths, unavailable} ->
        message = entry.message || %{}
        invocation = result_invocation(message, index)
        name = invocation.name

        if entry.type == :message and field(message, :role) in [:tool_result, "tool_result"] do
          details = field(message, :details) || %{}

          checkpoint_ids =
            field(details, :checkpoint_ids) || List.wrap(field(details, :checkpoint_id))

          debug_arguments = invocation.arguments

          cond do
            name in ["eval", "tool_invoke"] or
                (name == "debug" and not debug_inspection?(debug_arguments)) ->
              {paths, [name | unavailable]}

            is_list(checkpoint_ids) and checkpoint_ids != [] ->
              Enum.reduce(checkpoint_ids, {paths, unavailable}, fn checkpoint_id,
                                                                   {paths, unavailable} ->
                case checkpoint_files(checkpoint_id, session.header.cwd) do
                  {:ok, files} ->
                    paths =
                      Enum.reduce(files, paths, fn snapshot, acc ->
                        [
                          %{
                            checkpoint_id: checkpoint_id,
                            path: snapshot.path,
                            snapshot_digest: digest(snapshot)
                          }
                          | acc
                        ]
                      end)

                    {paths, unavailable}

                  {:error, _} ->
                    {paths, [name || "unknown" | unavailable]}
                end
              end)

            name in ["ast_grep", "lsp"] and
                MapSet.member?(
                  mutating_ids,
                  {field(message, :tool_name), field(message, :tool_call_id)}
                ) ->
              # A failed multi-file AST replacement or LSP edit may already have written some paths.
              {paths, [name | unavailable]}

            name in @mutation_tools ->
              {paths, [name | unavailable]}

            true ->
              {paths, unavailable}
          end
        else
          {paths, unavailable}
        end
      end)

    result_ids =
      suffix
      |> Enum.filter(
        &(field(&1.message, :role) in [:tool_result, "tool_result"] and
            is_binary(field(&1.message, :tool_call_id)))
      )
      |> MapSet.new(&{field(&1.message, :tool_name), field(&1.message, :tool_call_id)})

    interrupted =
      Enum.flat_map(mutating_calls, fn call ->
        if MapSet.member?(result_ids, {call.outer_name, call.id}),
          do: [],
          else: [call.name]
      end)

    {paths, (Enum.reverse(unavailable) ++ interrupted) |> Enum.uniq()}
  end

  defp mutating_call?(call) do
    name = call.name
    arguments = call.arguments

    name in @mutation_tools or name in ["eval", "tool_invoke"] or
      (name == "debug" and not debug_inspection?(arguments)) or
      (name == "ast_grep" and field(arguments, :action) == "replace" and
         field(arguments, :dry_run) == false) or
      (name == "lsp" and field(arguments, :apply) == true)
  end

  defp persisted_calls(suffix) do
    Enum.flat_map(suffix, fn entry ->
      case field(entry.message, :content) do
        blocks when is_list(blocks) ->
          blocks
          |> Enum.with_index()
          |> Enum.flat_map(fn {block, position} ->
            if field(block, :type) in [:tool_call, "tool_call"] do
              outer_name = field(block, :name)
              {name, arguments} = effective_invocation(outer_name, field(block, :arguments))

              [
                %{
                  id: field(block, :id) || {:entry, entry.id, position},
                  outer_name: outer_name,
                  name: name,
                  arguments: arguments
                }
              ]
            else
              []
            end
          end)

        _ ->
          []
      end
    end)
  end

  defp effective_invocation("tool_invoke", arguments) do
    case field(arguments, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> {"tool_invoke", nil}
          target -> {target, field(arguments, :args)}
        end

      _ ->
        {"tool_invoke", nil}
    end
  end

  defp effective_invocation(name, arguments), do: {name, arguments}

  defp call_index(calls), do: Map.new(calls, &{{&1.outer_name, &1.id}, &1})

  defp result_invocation(message, index) do
    Map.get(index, {field(message, :tool_name), field(message, :tool_call_id)}) ||
      %{name: field(message, :tool_name), arguments: field(message, :details)}
  end

  defp debug_inspection?(arguments),
    do: field(arguments, :action) in @debug_inspection_actions

  defp checkpoint_files(id, cwd) when is_binary(id) do
    with {:ok, checkpoint} <- Checkpoint.load(id),
         %{cwd: checkpoint_cwd, files: files} when is_binary(checkpoint_cwd) and is_list(files) <-
           get_in(checkpoint, [:state, :filesystem]),
         true <- Enum.all?(files, &(is_map(&1) and is_binary(Map.get(&1, :path)))),
         true <- Path.expand(checkpoint_cwd) == Path.expand(cwd) do
      {:ok, files}
    else
      _ -> {:error, :checkpoint_scope_mismatch}
    end
  end

  defp checkpoint_files(_, _), do: {:error, :invalid_checkpoint_id}

  defp fingerprints(_plan, false), do: {:ok, []}

  defp fingerprints(plan, true) do
    Enum.reduce_while(restore_paths(plan), {:ok, []}, fn path, {:ok, acc} ->
      case file_fingerprint(path) do
        {:ok, value} -> {:cont, {:ok, [{path, value} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp restore_paths(plan), do: plan |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()

  defp file_fingerprint(path), do: Checkpoint.filesystem_fingerprint(path)

  defp revision(session),
    do: {session.header.id, session.leaf_id, SessionManager.entry_count(session)}

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value))

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil

  defp preview(%{type: :message, message: message}) do
    if field(message, :role) in [:user, "user", :assistant, "assistant"] do
      message |> message_text() |> LemonCore.Redact.text(strict: true) |> String.slice(0, 240)
    else
      ""
    end
  end

  defp preview(_), do: ""

  @doc "A stored label as projected to clients: strictly redacted, like tree text."
  @spec project_label(String.t() | nil) :: String.t() | nil
  def project_label(nil), do: nil
  def project_label(label), do: LemonCore.Redact.text(label, strict: true)

  defp message_text(message) do
    case field(message, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        Enum.map_join(blocks, "", fn block ->
          text = field(block, :text)
          if field(block, :type) in [:text, "text"] and is_binary(text), do: text, else: ""
        end)

      _ ->
        ""
    end
  end

  # `prompt` is an editing projection, not a replay payload. Inspect the original
  # journal message without copying media into the preview or another store.
  defp message_contains_non_text?(message) when is_map(message) do
    contents =
      for key <- [:content, "content"], Map.has_key?(message, key), do: Map.fetch!(message, key)

    contents == [] or not Enum.all?(contents, &text_only_content?/1) or
      Enum.any?([:images, :image, :image_url, :attachments], fn key ->
        Enum.any?([key, Atom.to_string(key)], fn spelling ->
          Map.get(message, spelling) not in [nil, []]
        end)
      end)
  end

  defp message_contains_non_text?(_), do: true

  defp text_only_content?(text) when is_binary(text), do: true

  defp text_only_content?(blocks) when is_list(blocks) do
    Enum.all?(blocks, fn block ->
      field(block, :type) in [:text, "text"] and is_binary(field(block, :text))
    end)
  end

  defp text_only_content?(_), do: false
end
