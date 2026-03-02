defmodule CodingAgent.Session.BranchManager do
  @moduledoc """
  Manages branch navigation and summarization within a session tree.

  Handles detecting branch switches, summarizing abandoned branches,
  and orchestrating branch navigation transitions.
  """

  alias CodingAgent.Session.CompactionManager
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  # ============================================================================
  # Branch Switch Detection
  # ============================================================================

  @doc """
  Determines if navigation constitutes a branch switch (abandoning the current branch).

  A branch switch occurs when:
  1. The target entry is not on the current branch path, OR
  2. The target entry is an ancestor of the current leaf (going back in history)
  """
  @spec branch_switch?([SessionEntry.t()], [SessionEntry.t()], String.t() | nil, String.t()) ::
          boolean()
  def branch_switch?(_current_branch, _new_branch, nil, _target_id), do: false
  def branch_switch?(_current_branch, _new_branch, _current_leaf_id, nil), do: false

  def branch_switch?(current_branch, new_branch, current_leaf_id, target_id) do
    # Get IDs on each branch path
    current_ids = MapSet.new(Enum.map(current_branch, & &1.id))
    new_ids = MapSet.new(Enum.map(new_branch, & &1.id))

    cond do
      # Target is current leaf - no switch
      target_id == current_leaf_id ->
        false

      # Target not on current branch - definitely a switch
      not MapSet.member?(current_ids, target_id) ->
        true

      # Target is on current branch but current leaf not on new branch
      # This means we're going back to an ancestor, abandoning the current extension
      not MapSet.member?(new_ids, current_leaf_id) ->
        true

      # Both are on each other's paths - just moving within same linear history
      true ->
        false
    end
  end

  # ============================================================================
  # Branch Summarization
  # ============================================================================

  @doc """
  Attempts to summarize the abandoned branch asynchronously.

  Spawns a background task to generate a summary and sends the result back to
  the session process. Returns the state unchanged (summarization happens in
  background).
  """
  @spec maybe_summarize_abandoned_branch(map(), [SessionEntry.t()], String.t() | nil) :: map()
  def maybe_summarize_abandoned_branch(state, _branch_entries, nil), do: state

  def maybe_summarize_abandoned_branch(state, branch_entries, from_id) do
    # Check if there are message entries worth summarizing
    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if length(message_entries) >= 2 do
      # Summarize asynchronously to not block navigation
      session_pid = self()
      model = state.model

      _ =
        CompactionManager.start_background_task(fn ->
          case CodingAgent.Compaction.generate_branch_summary(branch_entries, model, []) do
            {:ok, summary} ->
              # Send a message back to the session to store the summary
              send(session_pid, {:store_branch_summary, from_id, summary})

            {:error, _reason} ->
              # Silently ignore summarization failures for abandoned branches
              :ok
          end
        end)
    end

    state
  end

  # ============================================================================
  # Branch Navigation
  # ============================================================================

  @doc """
  Handles branch navigation to a specific entry in the session tree.

  Detects branch switches, triggers summarization of abandoned branches,
  and updates the session manager and agent messages accordingly.

  Returns `{:ok, new_state}` on success or `{:error, reason}` if the entry
  is not found.
  """
  @spec navigate(map(), String.t(), keyword(), (map() -> [map()])) ::
          {:ok, map()} | {:error, :entry_not_found}
  def navigate(state, entry_id, opts, restore_messages_fn) do
    case SessionManager.get_entry(state.session_manager, entry_id) do
      nil ->
        {:error, :entry_not_found}

      _entry ->
        # Check if we're navigating away from the current branch
        current_leaf_id = SessionManager.get_leaf_id(state.session_manager)
        current_branch = SessionManager.get_branch(state.session_manager)
        new_branch = SessionManager.get_branch(state.session_manager, entry_id)

        # Determine if this is a branch switch (not just moving within the same branch)
        is_branch_switch =
          branch_switch?(current_branch, new_branch, current_leaf_id, entry_id)

        # Summarize abandoned branch if switching branches and option not disabled
        state =
          if is_branch_switch and Keyword.get(opts, :summarize_abandoned, true) do
            maybe_summarize_abandoned_branch(state, current_branch, current_leaf_id)
          else
            state
          end

        session_manager = SessionManager.set_leaf_id(state.session_manager, entry_id)

        # Rebuild messages from the new position
        messages = restore_messages_fn.(session_manager)
        :ok = AgentCore.Agent.replace_messages(state.agent, messages)

        {:ok, %{state | session_manager: session_manager}}
    end
  end

  # ============================================================================
  # Branch Summary Creation
  # ============================================================================

  @doc """
  Creates a summary for the current branch.

  Returns `{:ok, new_state}` on success, `{:error, :empty_branch}` if there are
  no messages to summarize, or `{:error, reason}` if summarization fails.

  Accepts callback functions for UI interactions and event broadcasting.
  """
  @spec summarize_current_branch(
          map(),
          keyword(),
          (map(), term() -> :ok),
          (map(), String.t() | nil -> :ok),
          (map(), String.t(), atom() -> :ok)
        ) ::
          {:ok, map()} | {:error, term()}
  def summarize_current_branch(state, opts, broadcast_event_fn, ui_set_working_fn, ui_notify_fn) do
    # Get the current branch entries
    branch_entries = SessionManager.get_branch(state.session_manager)

    # Check if there are any message entries to summarize
    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if Enum.empty?(message_entries) do
      {:error, :empty_branch}
    else
      # Show working message before summarization
      ui_set_working_fn.(state, "Summarizing branch...")

      case CodingAgent.Compaction.generate_branch_summary(branch_entries, state.model, opts) do
        {:ok, summary} ->
          # Get the current leaf_id to use as from_id
          from_id = SessionManager.get_leaf_id(state.session_manager)

          # Create branch summary entry
          entry = SessionEntry.branch_summary(from_id, summary)

          # Append to session manager
          session_manager = SessionManager.append_entry(state.session_manager, entry)

          # Broadcast branch summary event to listeners
          broadcast_event_fn.(state, {:branch_summarized, %{from_id: from_id, summary: summary}})

          # Clear working message
          ui_set_working_fn.(state, nil)

          {:ok, %{state | session_manager: session_manager}}

        {:error, reason} ->
          ui_set_working_fn.(state, nil)
          ui_notify_fn.(state, "Branch summarization failed: #{inspect(reason)}", :error)
          {:error, reason}
      end
    end
  end
end
