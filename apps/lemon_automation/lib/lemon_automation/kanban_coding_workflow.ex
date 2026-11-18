defmodule LemonAutomation.KanbanCodingWorkflow do
  @moduledoc """
  Opt-in leased coding → independent review → exact-tree commit → publication.

  Router identities and every mutation intent are durable before dispatch. A
  reviewer may request one corrective coding pass; a second rejection blocks the
  card. Local commits use a compare-and-swap branch update. Publication is never
  enabled implicitly and an uncertain push/PR creation is only queried, not retried.
  Restart recovery keeps the original lease, base tree, configuration and run IDs.

  Controller-owned side effects are authorized against the card's current
  recorded authority (`KanbanRunWorker.effective_policy/2`), not the workflow
  settings: a commit needs workspace writes without approval
  (`:commit_not_authorized`); a push or pull request additionally needs the
  board's recorded publication grant for these exact settings and a policy that
  permits shell and external access without approval
  (`:publication_not_authorized`).
  """

  alias LemonAgent.Workspace.{KanbanAuthority, KanbanStore}
  alias LemonAutomation.{KanbanGitWorkflow, KanbanReview, KanbanRunWorker, RunCompletionWaiter}
  alias LemonCore.{Id, RunStore}

  @reconcile_interval_ms 5_000
  @session_provenance "kanban-dispatcher/v2"

  def run(task, workspace, raw_config, opts) do
    saved = task.meta["codingWorkflow"]
    raw_config = if is_map(saved), do: saved["config"], else: raw_config
    git_opts = Keyword.get(opts, :git_opts, [])
    prepare_opts = if is_map(saved), do: Keyword.put(git_opts, :checkpoint, saved), else: git_opts

    with {:ok, config} when is_map(config) <- KanbanGitWorkflow.normalize(raw_config),
         {:ok, base} <- KanbanGitWorkflow.prepare(workspace, task, config, prepare_opts) do
      checkpoint = Map.merge(saved || %{}, base) |> Map.put("config", raw_config)

      context = %{
        task: task,
        workspace: workspace,
        config: config,
        opts: opts,
        git_opts: git_opts
      }

      cond do
        checkpoint["cancelRequested"] == true ->
          cancel_recovery(context, checkpoint)

        recovering?(task) ->
          resume(context, checkpoint)

        checkpoint["phase"] in ["commit_pending", "committed", "publish_pending", "completed"] ->
          resume(context, checkpoint)

        true ->
          code(context, Map.put(checkpoint, "round", 1))
      end
    else
      {:ok, nil} -> {:error, :invalid_coding_workflow}
      {:error, reason} -> {:error, reason}
    end
  end

  def workflow?(task), do: is_map(get_in(task, [:meta, "codingWorkflow"]))

  def ready_to_resume?(task) do
    checkpoint = get_in(task, [:meta, "codingWorkflow"]) || %{}
    due? = (checkpoint["reconcileAfterMs"] || 0) <= System.system_time(:millisecond)

    due? and
      case checkpoint["phase"] do
        "coding" ->
          terminal?(checkpoint["codingRunId"])

        "review" ->
          terminal?(checkpoint["reviewRunId"])

        phase ->
          phase in [
            "coding_complete",
            "review_rejected",
            "commit_pending",
            "committed",
            "publish_pending",
            "completed"
          ]
      end
  end

  defp recovering?(task),
    do: get_in(task, [:meta, "kanbanRun", "status"]) in ["running", "outcome_unknown"]

  defp resume(context, checkpoint) do
    case checkpoint["phase"] do
      "coding" ->
        case completion(checkpoint["codingRunId"]) do
          {:ok, output} -> coded(context, checkpoint, output)
          {:error, :not_terminal} -> unknown(context, checkpoint)
          {:error, _} -> {:error, :coding_run_failed}
        end

      "coding_complete" ->
        review(context, checkpoint)

      "review" ->
        case completion(checkpoint["reviewRunId"]) do
          {:ok, output} -> reviewed(context, checkpoint, output)
          {:error, :not_terminal} -> unknown(context, checkpoint)
          {:error, _} -> {:error, :review_run_failed}
        end

      "review_rejected" ->
        revise(context, checkpoint)

      "commit_pending" ->
        recover_commit(context, checkpoint)

      "committed" ->
        publish(context, checkpoint)

      "publish_pending" ->
        recover_publication(context, checkpoint)

      "completed" ->
        success(checkpoint)

      _ ->
        {:error, :invalid_workflow_checkpoint}
    end
  end

  defp code(context, checkpoint) do
    run_id = Id.run_id()

    # Continue only a coding session this controller recorded in its own
    # lease-guarded checkpoint; legacy checkpoints start a fresh session.
    trusted =
      if checkpoint["sessionProvenance"] == @session_provenance,
        do: checkpoint["codingSessionKey"]

    opts = Keyword.put(context.opts, :trusted_session_key, trusted)

    with {:ok, params} <- KanbanRunWorker.build_params(context.task, run_id, opts) do
      checkpoint =
        checkpoint
        |> Map.merge(%{
          "phase" => "coding",
          "codingRunId" => run_id,
          "codingSessionKey" => params.session_key,
          "sessionProvenance" => @session_provenance
        })
        |> Map.delete("reconcileAfterMs")

      opts =
        opts
        |> Keyword.put(:trusted_session_key, params.session_key)
        |> Keyword.put(:run_id, run_id)
        |> Keyword.put(:prompt, coding_prompt(params.prompt, checkpoint))
        |> Keyword.put(:on_submitting, fn id, attrs -> claim(context, id, attrs, checkpoint) end)

      case KanbanRunWorker.run_coding(context.task, context.workspace, opts) do
        {:ok, %{output: output}} -> coded(context, checkpoint, output)
        {:outcome_unknown, _} -> unknown(context, checkpoint)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp coded(context, checkpoint, output) do
    checkpoint =
      Map.merge(checkpoint, %{
        "phase" => "coding_complete",
        "codingOutput" => bounded(output, 12_000)
      })

    with :ok <- persist(context, checkpoint) do
      review(context, checkpoint)
    end
  end

  defp review(context, checkpoint) do
    run_id = Id.run_id()

    with {:ok, %{"changed" => true} = snapshot} <-
           KanbanGitWorkflow.snapshot(checkpoint, context.git_opts),
         {:ok, params} <-
           KanbanReview.params(
             context.task,
             checkpoint,
             snapshot,
             context.config,
             run_id,
             context.opts
           ),
         {:ok, params} <- KanbanRunWorker.bind_execution(params, context.workspace) do
      checkpoint =
        Map.merge(checkpoint, %{
          "phase" => "review",
          "reviewRunId" => run_id,
          "reviewSessionKey" => params.session_key,
          "snapshot" => Map.delete(snapshot, "diff")
        })

      attrs = %{
        "sessionKey" => checkpoint["codingSessionKey"],
        "cwd" => checkpoint["cwd"],
        "branch" => checkpoint["branch"]
      }

      case RunCompletionWaiter.submit_and_wait(params,
             router_mod: Keyword.get(context.opts, :router_mod, LemonRouter),
             waiter_mod: Keyword.get(context.opts, :waiter_mod, RunCompletionWaiter),
             bus_mod: Keyword.get(context.opts, :bus_mod, LemonCore.Bus),
             timeout_ms: Keyword.get(context.opts, :timeout_ms, 300_000),
             wait_opts: Keyword.get(context.opts, :wait_opts, []),
             on_submitting: fn id ->
               with :ok <- LemonAutomation.RunNotifications.bind_kanban(context.task, params),
                    do: claim(context, id, attrs, checkpoint)
             end
           ) do
        {:ok, _id, output} ->
          reviewed(context, checkpoint, output)

        {:error, {kind, _id}}
        when kind in [:timeout, :submission_outcome_unknown, :completion_outcome_unknown] ->
          unknown(context, checkpoint)

        {:error, {:unexpected_run_id, _, _}} ->
          unknown(context, checkpoint)

        {:error, _} ->
          {:error, :review_run_failed}
      end
    else
      {:ok, %{"changed" => false}} -> {:error, :no_code_changes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reviewed(context, checkpoint, output) do
    with {:ok, verdict} <- KanbanReview.parse(output) do
      phase = if verdict["approved"], do: "commit_pending", else: "review_rejected"
      checkpoint = Map.merge(checkpoint, %{"phase" => phase, "review" => verdict})

      with :ok <- persist(context, checkpoint) do
        if verdict["approved"], do: commit(context, checkpoint), else: revise(context, checkpoint)
      end
    end
  end

  defp revise(context, checkpoint) do
    if checkpoint["round"] < 2,
      do: code(context, Map.update!(checkpoint, "round", &(&1 + 1))),
      else: {:error, :review_rejected}
  end

  defp commit(context, checkpoint) do
    case KanbanGitWorkflow.commit(
           checkpoint,
           checkpoint["snapshot"],
           context.task.title,
           Keyword.put(context.git_opts, :authorize, commit_authorizer(context))
         ) do
      {:ok, sha} -> committed(context, checkpoint, sha)
      {:error, :commit_outcome_unknown} -> unknown(context, checkpoint)
      {:error, reason} -> {:error, reason}
    end
  end

  # Each commit command, exactly as built and run, against the card's current
  # recorded policy: workspace writes, command allow/block lists and approvals.
  defp commit_authorizer(context) do
    case KanbanRunWorker.effective_policy(context.task) do
      {:ok, policy} ->
        fn command ->
          if KanbanAuthority.commit_permitted?(policy, [KanbanAuthority.command_text(command)]),
            do: :ok,
            else: {:error, :commit_not_authorized}
        end

      {:error, _} ->
        fn _command -> {:error, :commit_not_authorized} end
    end
  end

  # Publication and reconciliation: the board's current operator grant for
  # exactly these settings (its pinned destinations are the only push URLs
  # used) and the card's current recorded policy (external access without
  # approval). Each command is then authorized exactly as built and run.
  defp publication_opts(context, checkpoint) do
    board = KanbanStore.get_board(context.task.board_id)
    settings = get_in(checkpoint, ["config", "publish"])

    with {:ok, authority} <- KanbanAuthority.fetch(board),
         {:ok, destinations} <- KanbanAuthority.granted_destinations(authority, settings),
         {:ok, policy} <- KanbanRunWorker.effective_policy(context.task, board),
         true <- KanbanAuthority.publication_permitted?(policy, []) do
      authorize = fn command ->
        if KanbanAuthority.publication_permitted?(policy, [KanbanAuthority.command_text(command)]),
           do: :ok,
           else: {:error, :publication_not_authorized}
      end

      {:ok,
       context.git_opts
       |> Keyword.put(:authorize, authorize)
       |> Keyword.put(:destinations, destinations["push"])}
    else
      _ -> {:error, :publication_not_authorized}
    end
  end

  defp recover_commit(context, checkpoint) do
    case KanbanGitWorkflow.reconcile_commit(checkpoint, checkpoint["snapshot"], context.git_opts) do
      {:ok, sha} ->
        committed(context, checkpoint, sha)

      {:error, _} ->
        # This mutation is independently idempotent: the exact reviewed tree and
        # expected parent bind the branch compare-and-swap. A second writer cannot
        # replace the first writer's commit or create a second branch commit.
        commit(context, checkpoint)
    end
  end

  defp committed(context, checkpoint, sha) do
    checkpoint = Map.merge(checkpoint, %{"phase" => "committed", "commitSha" => sha})
    with :ok <- persist(context, checkpoint), do: publish(context, checkpoint)
  end

  defp publish(%{config: %{publish: nil}} = context, checkpoint),
    do: finish(context, Map.put(checkpoint, "published", false))

  defp publish(context, checkpoint) do
    checkpoint = Map.put(checkpoint, "phase", "publish_pending")

    # Refuse before recording a pending publication when nothing could run.
    with {:ok, opts} <- publication_opts(context, checkpoint),
         :ok <- persist(context, checkpoint) do
      case KanbanGitWorkflow.publish(
             checkpoint,
             checkpoint["commitSha"],
             context.config,
             context.task.title,
             publication_body(checkpoint),
             opts
           ) do
        {:ok, result} -> finish(context, Map.merge(checkpoint, result))
        {:error, :publication_outcome_unknown} -> unknown(context, checkpoint)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Recovery runs only commands the current grant and policy authorize; a
  # revoked grant or narrowed policy fails the card without network access.
  defp recover_publication(context, checkpoint) do
    with {:ok, opts} <- publication_opts(context, checkpoint) do
      case KanbanGitWorkflow.reconcile_publication(
             checkpoint,
             checkpoint["commitSha"],
             context.config,
             opts
           ) do
        {:ok, result} -> finish(context, Map.merge(checkpoint, result))
        {:error, :publication_not_authorized} = denied -> denied
        {:error, _} -> unknown(context, checkpoint)
      end
    end
  end

  defp finish(context, checkpoint) do
    checkpoint = checkpoint |> Map.put("phase", "completed") |> Map.delete("reconcileAfterMs")
    with :ok <- persist(context, checkpoint), do: success(checkpoint)
  end

  defp success(checkpoint) do
    output = publication_body(checkpoint)

    output =
      if checkpoint["prUrl"],
        do: output <> "\nPull request: " <> checkpoint["prUrl"],
        else: output

    {:ok, %{run_id: checkpoint["reviewRunId"], output: output}}
  end

  defp unknown(context, checkpoint) do
    checkpoint =
      Map.put(
        checkpoint,
        "reconcileAfterMs",
        System.system_time(:millisecond) + @reconcile_interval_ms
      )

    with :ok <- persist(context, checkpoint), do: {:outcome_unknown, current_run(checkpoint)}
  end

  defp cancel_recovery(context, %{"phase" => "publish_pending"} = checkpoint) do
    with {:ok, opts} <- publication_opts(context, checkpoint) do
      case KanbanGitWorkflow.reconcile_publication(
             checkpoint,
             checkpoint["commitSha"],
             context.config,
             opts
           ) do
        {:ok, result} ->
          with :ok <- persist(context, Map.merge(checkpoint, result)), do: {:error, :cancelled}

        {:error, :publication_not_authorized} = denied ->
          denied

        {:error, _} ->
          unknown(context, checkpoint)
      end
    end
  end

  defp cancel_recovery(_context, _checkpoint), do: {:error, :cancelled}

  defp claim(context, run_id, attrs, checkpoint) do
    attrs = Map.put(attrs, "codingWorkflow", checkpoint)
    callback = Keyword.get(context.opts, :on_submitting)

    if is_function(callback, 2) do
      callback.(run_id, attrs)
    else
      case KanbanStore.track_leased_run(context.task.id, lease_id(context.task), run_id, attrs) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist(context, checkpoint) do
    callback = Keyword.get(context.opts, :on_checkpoint)

    if is_function(callback, 1) do
      callback.(checkpoint)
    else
      case KanbanStore.checkpoint_leased_workflow(
             context.task.id,
             lease_id(context.task),
             checkpoint
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp current_run(%{"phase" => "coding"} = checkpoint), do: checkpoint["codingRunId"]
  defp current_run(checkpoint), do: checkpoint["reviewRunId"] || checkpoint["codingRunId"]
  defp lease_id(task), do: get_in(task, [:meta, "kanbanLease", "id"])

  defp terminal?(run_id), do: completion(run_id) != {:error, :not_terminal}

  defp completion(run_id) when is_binary(run_id) do
    case RunStore.get(run_id) do
      %{summary: summary} when is_map(summary) ->
        RunCompletionWaiter.extract_output_from_completion(summary)

      _ ->
        {:error, :not_terminal}
    end
  end

  defp completion(_), do: {:error, :not_terminal}

  defp coding_prompt(prompt, checkpoint) do
    feedback = get_in(checkpoint, ["review", "findings"])

    revision =
      if is_binary(feedback),
        do: "\nAddress the independent review findings before finishing:\n#{feedback}\n",
        else: ""

    prompt <>
      """

      This card uses a controller-owned review and commit workflow. Modify and
      verify the code in this isolated checkout, but do not commit, push, open a
      pull request, or change Git configuration. The controller will independently
      review the full diff and commit the exact approved tree. Do not waive review.
      """ <> revision
  end

  defp publication_body(checkpoint) do
    """
    #{checkpoint["codingOutput"] || "Coding change completed."}

    Independent review: approved (run #{checkpoint["reviewRunId"]}).
    Reviewed tree: #{get_in(checkpoint, ["snapshot", "tree"])}
    Branch: #{checkpoint["branch"]}
    Commit: #{checkpoint["commitSha"]}
    """
    |> String.trim()
  end

  defp bounded(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes, do: value, else: value |> String.slice(0, div(max_bytes, 4))
  end

  defp bounded(_, _), do: ""
end
