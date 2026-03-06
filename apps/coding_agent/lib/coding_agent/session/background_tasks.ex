defmodule CodingAgent.Session.BackgroundTasks do
  @moduledoc false

  alias CodingAgent.Session.CompactionManager
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  @type callbacks(state) :: %{
          required(:broadcast_event) => (state, AgentCore.Types.agent_event() -> :ok),
          required(:ui_set_working_message) => (state, String.t() | nil -> :ok),
          required(:ui_notify) => (state, String.t(), CodingAgent.UI.notify_type() -> :ok)
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
    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if length(message_entries) >= 2 do
      model = state.model

      _ =
        CompactionManager.start_background_task(fn ->
          case CodingAgent.Compaction.generate_branch_summary(branch_entries, model, []) do
            {:ok, summary} ->
              send(session_pid, {:store_branch_summary, from_id, summary})

            {:error, _reason} ->
              :ok
          end
        end)
    end

    state
  end

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

    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if Enum.empty?(message_entries) do
      {:error, :empty_branch, state}
    else
      callbacks.ui_set_working_message.(state, "Summarizing branch...")

      case CodingAgent.Compaction.generate_branch_summary(branch_entries, state.model, opts) do
        {:ok, summary} ->
          from_id = SessionManager.get_leaf_id(state.session_manager)
          new_state = store_branch_summary(state, from_id, summary, callbacks)
          callbacks.ui_set_working_message.(new_state, nil)
          {:ok, new_state}

        {:error, reason} ->
          callbacks.ui_set_working_message.(state, nil)
          callbacks.ui_notify.(state, "Branch summarization failed: #{inspect(reason)}", :error)
          {:error, reason, state}
      end
    end
  end
end
