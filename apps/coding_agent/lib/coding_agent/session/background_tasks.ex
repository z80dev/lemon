defmodule CodingAgent.Session.BackgroundTasks do
  @moduledoc false

  alias CodingAgent.Session.CompactionManager
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  @type callbacks(state) :: %{
          required(:broadcast_event) => (state, LemonAgent.Types.agent_event() -> :ok)
        }

  @spec flush_queued_agent_events() :: :ok
  def flush_queued_agent_events do
    receive do
      {:agent_event, _event} ->
        flush_queued_agent_events()
    after
      0 ->
        :ok
    end
  end

  @spec maybe_summarize_abandoned_branch(map(), [SessionEntry.t()], String.t() | nil, pid()) ::
          map()
  def maybe_summarize_abandoned_branch(state, _branch_entries, nil, _session_pid), do: state

  def maybe_summarize_abandoned_branch(state, branch_entries, from_id, session_pid) do
    if summarizable?(branch_entries) do
      model = state.model
      opts = CompactionManager.summary_options([], state)

      _ =
        CompactionManager.start_background_task(fn ->
          case CodingAgent.Compaction.generate_branch_summary(branch_entries, model, opts) do
            {:ok, summary} ->
              send(session_pid, {:store_branch_summary, from_id, summary})

            {:error, _reason} ->
              :ok
          end
        end)
    end

    state
  end

  @doc """
  Whether moving the active leaf to `target_id` abandons a branch that
  `maybe_summarize_abandoned_branch/4` summarizes: a real branch switch away
  from at least two messages.
  """
  @spec summarizes_switch?(SessionManager.Session.t(), String.t() | nil) :: boolean()
  def summarizes_switch?(session_manager, target_id) do
    current_branch = SessionManager.get_branch(session_manager)
    new_branch = SessionManager.get_branch(session_manager, target_id)
    current_leaf_id = SessionManager.get_leaf_id(session_manager)

    branch_switch?(current_branch, new_branch, current_leaf_id, target_id) and
      summarizable?(current_branch)
  end

  defp summarizable?(branch_entries),
    do: Enum.count(branch_entries, &(&1.type == :message and &1.message != nil)) >= 2

  @spec branch_switch?([SessionEntry.t()], [SessionEntry.t()], String.t() | nil, String.t() | nil) ::
          boolean()
  def branch_switch?(_current_branch, _new_branch, nil, _target_id), do: false
  def branch_switch?(_current_branch, _new_branch, _current_leaf_id, nil), do: false

  def branch_switch?(current_branch, new_branch, current_leaf_id, target_id) do
    current_ids = MapSet.new(Enum.map(current_branch, & &1.id))
    new_ids = MapSet.new(Enum.map(new_branch, & &1.id))

    cond do
      target_id == current_leaf_id ->
        false

      not MapSet.member?(current_ids, target_id) ->
        true

      not MapSet.member?(new_ids, current_leaf_id) ->
        true

      true ->
        false
    end
  end

  @spec store_branch_summary(map(), String.t(), String.t(), callbacks(map())) :: map()
  def store_branch_summary(state, from_id, summary, callbacks) do
    entry = SessionEntry.branch_summary(from_id, summary)
    session_manager = SessionManager.append_entry(state.session_manager, entry)

    callbacks.broadcast_event.(state, {:branch_summarized, %{from_id: from_id, summary: summary}})

    %{state | session_manager: session_manager}
  end

  @spec summarize_branch(map(), keyword(), callbacks(map())) ::
          {:ok, map()} | {:error, term(), map()}
  def summarize_branch(state, opts, callbacks) do
    branch_entries = SessionManager.get_branch(state.session_manager)
    opts = CompactionManager.summary_options(opts, state)

    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if Enum.empty?(message_entries) do
      {:error, :empty_branch, state}
    else
      case CodingAgent.Compaction.generate_branch_summary(branch_entries, state.model, opts) do
        {:ok, summary} ->
          from_id = SessionManager.get_leaf_id(state.session_manager)
          {:ok, store_branch_summary(state, from_id, summary, callbacks)}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end
end
