defmodule CodingAgent.Test.MockUI do
  @moduledoc """
  Mock UI implementation for testing UI interactions.

  This module tracks all UI method calls using ETS for cross-process visibility.
  The tracker table can be accessed from any process, making it suitable for
  testing GenServers that call UI methods.

  ## Usage

      # In your test setup
      tracker = CodingAgent.Test.MockUI.start_tracker()

      # Create a UI context with the mock
      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # ... run your test ...

      # Verify calls were made
      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_working_message, ["Compacting context..."]} in calls

      # Cleanup
      CodingAgent.Test.MockUI.stop_tracker(tracker)
  """

  @behaviour CodingAgent.UI

  # ============================================================================
  # Tracker Management
  # ============================================================================

  @doc """
  Starts a new call tracker using ETS.
  Returns the tracker table reference.
  """
  def start_tracker do
    table = :ets.new(:mock_ui_tracker, [:ordered_set, :public, :named_table])
    :ets.insert(table, {:counter, 0})
    table
  end

  @doc """
  Starts a tracker with a unique name (for parallel tests).
  Returns the tracker table reference.
  """
  def start_tracker(name) when is_atom(name) do
    table = :ets.new(name, [:ordered_set, :public])
    :ets.insert(table, {:counter, 0})
    table
  end

  @doc """
  Stops the tracker and cleans up.
  """
  def stop_tracker(tracker) do
    :ets.delete(tracker)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Gets all recorded calls from the tracker.
  Returns a list of `{function_name, args}` tuples in chronological order.
  """
  def get_calls(tracker) do
    tracker
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _val} -> is_integer(key) end)
    |> Enum.sort_by(fn {key, _val} -> key end)
    |> Enum.map(fn {_key, val} -> val end)
  end

  @doc """
  Clears all recorded calls from the tracker.
  """
  def clear_calls(tracker) do
    # Delete all entries except counter
    :ets.match_delete(tracker, {:"$1", :_})
    :ets.insert(tracker, {:counter, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Registers the tracker for the current process.
  This must be called in any process that will make UI calls.
  """
  def register_tracker(tracker) do
    Process.put(:mock_ui_tracker, tracker)
  end

  @doc """
  Sets the global tracker (for simpler test setup).
  Uses a named ETS table that any process can access.
  """
  def set_global_tracker(tracker) do
    # Store in persistent term for global access
    :persistent_term.put(:mock_ui_global_tracker, tracker)
  end

  @doc """
  Clears the global tracker.
  """
  def clear_global_tracker do
    :persistent_term.erase(:mock_ui_global_tracker)
  rescue
    ArgumentError -> :ok
  end

  # Record a call to the tracker
  defp record_call(function, args) do
    tracker = get_tracker()

    if tracker do
      counter = :ets.update_counter(tracker, :counter, 1)
      :ets.insert(tracker, {counter, {function, args}})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp get_tracker do
    # First check process dictionary, then global tracker
    case Process.get(:mock_ui_tracker) do
      nil ->
        try do
          :persistent_term.get(:mock_ui_global_tracker)
        rescue
          ArgumentError -> nil
        end

      tracker ->
        tracker
    end
  end

  # ============================================================================
  # Dialog methods
  # ============================================================================

  @impl CodingAgent.UI
  def select(title, options, opts \\ []) do
    record_call(:select, [title, options, opts])
    {:ok, nil}
  end

  @impl CodingAgent.UI
  def confirm(title, message, opts \\ []) do
    record_call(:confirm, [title, message, opts])
    {:ok, false}
  end

  @impl CodingAgent.UI
  def input(title, placeholder \\ nil, opts \\ []) do
    record_call(:input, [title, placeholder, opts])
    {:ok, nil}
  end

  @impl CodingAgent.UI
  def notify(message, type) do
    record_call(:notify, [message, type])
    :ok
  end

  # ============================================================================
  # Status/widget methods
  # ============================================================================

  @impl CodingAgent.UI
  def set_status(key, text) do
    record_call(:set_status, [key, text])
    :ok
  end

  @impl CodingAgent.UI
  def set_widget(key, content, opts \\ []) do
    record_call(:set_widget, [key, content, opts])
    :ok
  end

  @impl CodingAgent.UI
  def set_working_message(message) do
    record_call(:set_working_message, [message])
    :ok
  end

  # ============================================================================
  # Layout methods
  # ============================================================================

  @impl CodingAgent.UI
  def set_title(title) do
    record_call(:set_title, [title])
    :ok
  end

  # ============================================================================
  # Editor methods
  # ============================================================================

  @impl CodingAgent.UI
  def set_editor_text(text) do
    record_call(:set_editor_text, [text])
    :ok
  end

  @impl CodingAgent.UI
  def get_editor_text do
    record_call(:get_editor_text, [])
    ""
  end

  @impl CodingAgent.UI
  def editor(title, prefill \\ nil, opts \\ []) do
    record_call(:editor, [title, prefill, opts])
    {:ok, nil}
  end

  # ============================================================================
  # Capability check
  # ============================================================================

  @impl CodingAgent.UI
  def has_ui? do
    record_call(:has_ui?, [])
    true
  end
end
