defmodule CodingAgent.Session.Rewind do
  @moduledoc """
  Active-branch rewind with preview-bound, opt-in filesystem restoration.

  Rewind moves the cursor to immediately before a selected user message. The
  abandoned suffix remains in the session tree, but is no longer sent to the
  model. Files restore from the first recorded pre-mutation snapshot for each
  path in that suffix. Confirmation binds the branch revision and current file
  contents; it is stored server-side, expires after five minutes and is single use.
  """

  alias CodingAgent.SessionManager
  alias LemonCore.{Checkpoint, Store}

  @confirmation_table :session_rewinds
  @confirmation_ttl_ms 5 * 60 * 1000
  @mutation_tools ~w(write edit patch apply_patch bash)
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
          "label" => Map.get(labels, entry.id)
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
             "discardedMessages" => Enum.count(suffix, &(&1.type in [:message, :custom_message])),
             "restorePaths" => Enum.map(plan, & &1.path),
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
               "restoredPaths" => Enum.map(plan, & &1.path)
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
    case Checkpoint.create_filesystem(session.header.id, Enum.map(plan, & &1.path),
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
    {plan, unavailable} = restoration_plan(session, suffix)
    commands = shell_commands(suffix)
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

  defp shell_commands(suffix) do
    calls =
      Enum.flat_map(suffix, fn entry ->
        case field(entry.message, :content) do
          blocks when is_list(blocks) ->
            blocks
            |> Enum.with_index()
            |> Enum.flat_map(fn {block, index} ->
              if field(block, :type) in [:tool_call, "tool_call"] and
                   field(block, :name) == "bash" do
                id = field(block, :id) || {:entry, entry.id, index}
                [{id, field(field(block, :arguments), :command)}]
              else
                []
              end
            end)

          _ ->
            []
        end
      end)

    call_ids = MapSet.new(calls, &elem(&1, 0))

    missing =
      Enum.flat_map(suffix, fn entry ->
        message = entry.message
        id = field(message, :tool_call_id) || {:result, entry.id}

        if field(message, :role) in [:tool_result, "tool_result"] and
             field(message, :tool_name) == "bash" and not MapSet.member?(call_ids, id),
           do: [{id, nil}],
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

  defp restoration_plan(session, suffix) do
    mutating_calls =
      Enum.flat_map(suffix, fn entry ->
        case field(entry.message, :content) do
          blocks when is_list(blocks) -> Enum.filter(blocks, &mutating_call?/1)
          _ -> []
        end
      end)

    mutating_ids = MapSet.new(mutating_calls, &field(&1, :id))

    {paths, unavailable} =
      Enum.reduce(suffix, {%{}, []}, fn entry, {paths, unavailable} ->
        message = entry.message || %{}
        name = field(message, :tool_name)

        if entry.type == :message and field(message, :role) in [:tool_result, "tool_result"] do
          details = field(message, :details) || %{}
          checkpoint_id = field(details, :checkpoint_id)

          cond do
            is_binary(checkpoint_id) ->
              case checkpoint_files(checkpoint_id, session.header.cwd) do
                {:ok, files} ->
                  paths =
                    Enum.reduce(files, paths, fn snapshot, acc ->
                      Map.put_new(acc, snapshot.path, %{
                        checkpoint_id: checkpoint_id,
                        path: snapshot.path,
                        snapshot_digest: digest(snapshot)
                      })
                    end)

                  {paths, unavailable}

                {:error, _} ->
                  {paths, [name || "unknown" | unavailable]}
              end

            name == "ast_grep" and MapSet.member?(mutating_ids, field(message, :tool_call_id)) ->
              # A failed multi-file AST replacement may already have written some paths.
              {paths, [name | unavailable]}

            name in @mutation_tools and field(message, :is_error) != true ->
              {paths, [name | unavailable]}

            true ->
              {paths, unavailable}
          end
        else
          {paths, unavailable}
        end
      end)

    result_ids = MapSet.new(suffix, fn entry -> field(entry.message, :tool_call_id) end)

    interrupted =
      Enum.flat_map(mutating_calls, fn call ->
        if MapSet.member?(result_ids, field(call, :id)),
          do: [],
          else: [field(call, :name)]
      end)

    {paths |> Map.values() |> Enum.sort_by(& &1.path),
     (Enum.reverse(unavailable) ++ interrupted) |> Enum.uniq()}
  end

  defp mutating_call?(call) do
    arguments = field(call, :arguments)

    field(call, :type) in [:tool_call, "tool_call"] and
      (field(call, :name) in @mutation_tools or
         (field(call, :name) == "ast_grep" and field(arguments, :action) == "replace" and
            field(arguments, :dry_run) == false))
  end

  defp checkpoint_files(id, cwd) do
    with {:ok, checkpoint} <- Checkpoint.load(id),
         %{cwd: checkpoint_cwd, files: files} <- get_in(checkpoint, [:state, :filesystem]),
         true <- Path.expand(checkpoint_cwd) == Path.expand(cwd) do
      {:ok, files}
    else
      _ -> {:error, :checkpoint_scope_mismatch}
    end
  end

  defp fingerprints(_plan, false), do: {:ok, []}

  defp fingerprints(plan, true) do
    Enum.reduce_while(plan, {:ok, []}, fn item, {:ok, acc} ->
      case file_fingerprint(item.path) do
        {:ok, value} -> {:cont, {:ok, [{item.path, value} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp file_fingerprint(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %{type: :regular, mode: mode}} ->
        hash =
          path
          |> File.stream!(65_536, [])
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()

        {:ok, {mode, hash}}

      {:ok, _} ->
        {:error, :unsupported_file_type}

      {:error, _} ->
        {:error, :restore_failed}
    end
  rescue
    _ -> {:error, :restore_failed}
  end

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

  defp message_text(message) do
    case field(message, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        Enum.map_join(blocks, "", fn block ->
          if field(block, :type) in [:text, "text"], do: field(block, :text) || "", else: ""
        end)

      _ ->
        ""
    end
  end
end
