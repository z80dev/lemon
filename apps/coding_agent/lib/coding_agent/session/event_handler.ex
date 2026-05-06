defmodule CodingAgent.Session.EventHandler do
  @moduledoc false

  alias CodingAgent.Extensions
  alias LemonCore.Introspection

  @type callbacks(state) :: %{
          required(:set_working_message) => (state, String.t() | nil -> :ok),
          required(:notify) => (state, String.t(), CodingAgent.UI.notify_type() -> :ok),
          required(:complete_event_streams) => (state, term() -> :ok),
          required(:maybe_trigger_compaction) => (state -> state),
          required(:persist_message) => (state, term() -> state)
        }

  @spec handle(AgentCore.Types.agent_event(), state, callbacks(state)) :: state when state: map()
  def handle({:agent_start}, state, _callbacks) do
    # Execute on_agent_start hooks
    Extensions.execute_hooks(state.hooks, :on_agent_start, [])
    state
  end

  def handle({:turn_start}, state, _callbacks) do
    # Execute on_turn_start hooks
    Extensions.execute_hooks(state.hooks, :on_turn_start, [])
    state
  end

  def handle({:turn_end, message, tool_results}, state, callbacks) do
    # Execute on_turn_end hooks
    Extensions.execute_hooks(state.hooks, :on_turn_end, [message, tool_results])

    # Abort can terminate the underlying stream before {:canceled, reason} is observed.
    # Treat an aborted assistant turn as terminal to keep Session lifecycle consistent.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        callbacks.set_working_message.(state, nil)
        callbacks.complete_event_streams.(state, {:turn_end, message, tool_results})
        %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        state
    end
  end

  def handle({:message_start, message}, state, _callbacks) do
    # Execute on_message_start hooks
    Extensions.execute_hooks(state.hooks, :on_message_start, [message])
    state
  end

  def handle({:message_end, message}, state, callbacks) do
    # Execute on_message_end hooks
    Extensions.execute_hooks(state.hooks, :on_message_end, [message])

    new_state = callbacks.persist_message.(state, message)

    # Some abort paths can terminate after :message_end without emitting
    # :turn_end/:agent_end/:canceled. Treat aborted assistant messages as terminal
    # to avoid leaving the session in a permanently streaming state.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        callbacks.set_working_message.(new_state, nil)
        callbacks.complete_event_streams.(new_state, {:canceled, :assistant_aborted})
        %{new_state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        new_state
    end
  end

  def handle({:tool_execution_start, id, name, args}, state, callbacks) do
    # Execute on_tool_execution_start hooks
    Extensions.execute_hooks(state.hooks, :on_tool_execution_start, [id, name, args])

    # Emit introspection event for tool call dispatch
    Introspection.record(
      :tool_call_dispatched,
      %{
        tool_name: name,
        tool_call_id: id
      },
      engine: "lemon",
      provenance: :direct
    )

    callbacks.set_working_message.(state, "Running #{name}...")
    state
  end

  def handle({:tool_execution_end, id, name, result, is_error}, state, callbacks) do
    # Execute on_tool_execution_end hooks
    Extensions.execute_hooks(state.hooks, :on_tool_execution_end, [id, name, result, is_error])

    callbacks.set_working_message.(state, nil)
    state
  end

  def handle({:agent_end, messages}, state, callbacks) do
    # Execute on_agent_end hooks
    Extensions.execute_hooks(state.hooks, :on_agent_end, [messages])
    maybe_record_missed_skills(state, messages)
    maybe_record_missed_learning(state, messages)

    # Clear working message and steering queue
    callbacks.set_working_message.(state, nil)

    # Complete all event streams with the final event
    callbacks.complete_event_streams.(state, {:agent_end, messages})

    # Check if compaction is needed
    new_state = %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
    callbacks.maybe_trigger_compaction.(new_state)
  end

  def handle({:error, reason, partial_state}, state, callbacks) do
    callbacks.set_working_message.(state, nil)
    callbacks.notify.(state, "Agent error: #{inspect(reason)}", :error)

    # Complete all event streams with the error event
    callbacks.complete_event_streams.(state, {:error, reason, partial_state})

    %{state | is_streaming: false, event_streams: %{}}
  end

  def handle({:canceled, reason}, state, callbacks) do
    # Canceled is a terminal lifecycle event (e.g. abort) and may occur without :agent_end.
    callbacks.set_working_message.(state, nil)

    # Complete all event streams with the canceled event
    callbacks.complete_event_streams.(state, {:canceled, reason})

    %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
  end

  def handle(_event, state, _callbacks) do
    state
  end

  defp maybe_record_missed_skills(state, messages) do
    relevant_keys = extract_relevant_skill_keys(Map.get(state, :system_prompt, ""))
    loaded_keys = extract_loaded_skill_keys(messages)
    missed_keys = relevant_keys -- loaded_keys

    if missed_keys != [] do
      Introspection.record(
        :missed_skill_observed,
        %{
          missed_skill_keys: missed_keys,
          loaded_skill_keys: loaded_keys
        },
        session_key: session_key(state),
        agent_id: agent_id(state),
        engine: "lemon",
        provenance: :inferred
      )
    end
  end

  defp extract_relevant_skill_keys(prompt) when is_binary(prompt) do
    ~r/<relevant-skills>(.*?)<\/relevant-skills>/s
    |> Regex.scan(prompt, capture: :all_but_first)
    |> Enum.flat_map(fn [block] ->
      ~r/<key>\s*([^<]+?)\s*<\/key>/
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_relevant_skill_keys(_prompt), do: []

  defp extract_loaded_skill_keys(messages) when is_list(messages) do
    messages
    |> Enum.filter(&read_skill_result?/1)
    |> Enum.map(&skill_key_from_result/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_loaded_skill_keys(_messages), do: []

  defp read_skill_result?(%Ai.Types.ToolResultMessage{tool_name: "read_skill"}), do: true
  defp read_skill_result?(%{tool_name: "read_skill"}), do: true
  defp read_skill_result?(%{"tool_name" => "read_skill"}), do: true
  defp read_skill_result?(_message), do: false

  defp skill_key_from_result(%Ai.Types.ToolResultMessage{details: details}),
    do: skill_key_from_details(details)

  defp skill_key_from_result(%{details: details}), do: skill_key_from_details(details)
  defp skill_key_from_result(%{"details" => details}), do: skill_key_from_details(details)

  defp skill_key_from_details(%{key: key}) when is_binary(key), do: key
  defp skill_key_from_details(%{"key" => key}) when is_binary(key), do: key
  defp skill_key_from_details(_details), do: nil

  defp maybe_record_missed_learning(state, messages) do
    if learning_workflow_prompt?(Map.get(state, :system_prompt, "")) do
      triggers = learning_triggers(messages)
      used_tools = extract_tool_result_names(messages)
      missing_tools = recommended_learning_tools(triggers) -- used_tools

      if triggers != [] and missing_tools != [] do
        Introspection.record(
          :missed_learning_observed,
          %{
            triggers: triggers,
            missing_tools: missing_tools,
            used_learning_tools: Enum.filter(used_tools, &(&1 in learning_tool_names()))
          },
          session_key: session_key(state),
          agent_id: agent_id(state),
          engine: "lemon",
          provenance: :inferred
        )
      end
    end
  end

  defp learning_workflow_prompt?(prompt) when is_binary(prompt) do
    String.contains?(prompt, "<learning-workflow>")
  end

  defp learning_workflow_prompt?(_prompt), do: false

  defp learning_triggers(messages) when is_list(messages) do
    text =
      messages
      |> Enum.map(&message_text/1)
      |> Enum.join("\n")
      |> String.downcase()

    []
    |> maybe_add_trigger(:prior_memory, prior_memory_trigger?(text))
    |> maybe_add_trigger(:reusable_skill, reusable_skill_trigger?(text))
    |> maybe_add_trigger(:durable_memory, durable_memory_trigger?(text))
    |> Enum.reverse()
  end

  defp learning_triggers(_messages), do: []

  defp maybe_add_trigger(triggers, trigger, true), do: [trigger | triggers]
  defp maybe_add_trigger(triggers, _trigger, false), do: triggers

  defp prior_memory_trigger?(text) do
    text =~ ~r/\b(last time|previous(?:ly)?|prior work|past work|earlier|recall|remember when)\b/
  end

  defp reusable_skill_trigger?(text) do
    text =~
      ~r/\b(reusable workflow|recurring command|recurring workflow|debugging playbook|verification checklist|create a skill|new skill|learned? .*workflow|learned? .*command)\b/
  end

  defp durable_memory_trigger?(text) do
    text =~
      ~r/\b(remember this|store this|save this|durable (?:fact|decision|context|memory)|project context|preference|decision)\b/
  end

  defp recommended_learning_tools(triggers) do
    triggers
    |> Enum.flat_map(fn
      :prior_memory -> ["search_memory"]
      :reusable_skill -> ["skill_manage"]
      :durable_memory -> ["memory_topic"]
    end)
    |> Enum.uniq()
  end

  defp extract_tool_result_names(messages) when is_list(messages) do
    messages
    |> Enum.map(&tool_result_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_tool_result_names(_messages), do: []

  defp tool_result_name(%Ai.Types.ToolResultMessage{tool_name: name}) when is_binary(name),
    do: name

  defp tool_result_name(%{tool_name: name}) when is_binary(name), do: name
  defp tool_result_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp tool_result_name(_message), do: nil

  defp learning_tool_names, do: ["search_memory", "skill_manage", "memory_topic"]

  defp message_text(%Ai.Types.UserMessage{content: content}), do: content_text(content)
  defp message_text(%Ai.Types.AssistantMessage{content: content}), do: content_text(content)
  defp message_text(%Ai.Types.ToolResultMessage{content: content}), do: content_text(content)
  defp message_text(%{content: content}), do: content_text(content)
  defp message_text(%{"content" => content}), do: content_text(content)
  defp message_text(message) when is_binary(message), do: message
  defp message_text(_message), do: ""

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_block_text/1)
    |> Enum.join("\n")
  end

  defp content_text(_content), do: ""

  defp content_block_text(%Ai.Types.TextContent{text: text}) when is_binary(text), do: text
  defp content_block_text(%{text: text}) when is_binary(text), do: text
  defp content_block_text(%{"text" => text}) when is_binary(text), do: text
  defp content_block_text(text) when is_binary(text), do: text
  defp content_block_text(_block), do: ""

  defp session_key(%{session_manager: %{header: %{id: id}}}) when is_binary(id), do: id
  defp session_key(%{session_key: id}) when is_binary(id), do: id
  defp session_key(_state), do: nil

  defp agent_id(%{agent_id: id}) when is_binary(id), do: id
  defp agent_id(_state), do: "default"
end
