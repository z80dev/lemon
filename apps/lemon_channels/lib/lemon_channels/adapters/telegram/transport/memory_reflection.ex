defmodule LemonChannels.Adapters.Telegram.Transport.MemoryReflection do
  @moduledoc false

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonCore.{ChatScope, RouterBridge, RunRequest, RunStore}

  @type callbacks :: %{
          required(:maybe_subscribe_to_run) => (binary() -> term()),
          required(:current_thread_generation) => (map(), integer(), integer() | nil ->
                                                     non_neg_integer()),
          required(:maybe_put) => (map(), atom(), term() -> map())
        }

  @spec submit_before_new(
          map(),
          map(),
          ChatScope.t(),
          binary(),
          integer(),
          integer() | nil,
          integer() | nil,
          callbacks
        ) ::
          :ok | :skip
  def submit_before_new(
        state,
        inbound,
        %ChatScope{} = scope,
        session_key,
        chat_id,
        thread_id,
        user_msg_id,
        callbacks
      )
      when is_binary(session_key) do
    transcript =
      session_key
      |> RunStore.history(limit: 8)
      |> format_run_history_transcript(max_chars: 12_000)

    if transcript == "" do
      :skip
    else
      engine_id = PerChatState.last_engine_hint(session_key) || (inbound.meta || %{})[:engine_id]
      agent_id = (inbound.meta || %{})[:agent_id] || "default"

      {thinking_hint, _source} =
        ModelPolicyAdapter.resolve_thinking_hint(state.account_id, scope.chat_id, scope.topic_id)

      thread_generation = callbacks.current_thread_generation.(state, chat_id, thread_id)

      meta =
        (inbound.meta || %{})
        |> Map.put(:progress_msg_id, nil)
        |> Map.put(:status_msg_id, nil)
        |> Map.put(:topic_id, thread_id)
        |> Map.put(:thread_generation, thread_generation)
        |> Map.put(:user_msg_id, user_msg_id)
        |> Map.put(:command, :new)
        |> Map.put(:record_memories, true)
        |> callbacks.maybe_put.(:thinking_level, thinking_hint)
        |> Map.merge(%{
          channel_id: inbound.channel_id,
          account_id: inbound.account_id,
          peer: inbound.peer,
          sender: inbound.sender,
          raw: inbound.raw
        })

      request =
        RunRequest.new(%{
          origin: :channel,
          session_key: reflection_session_key(session_key),
          agent_id: agent_id,
          prompt: memory_reflection_prompt(transcript),
          queue_mode: :collect,
          engine_id: engine_id,
          meta: meta
        })

      case RouterBridge.submit_run(request) do
        {:ok, run_id} when is_binary(run_id) ->
          callbacks.maybe_subscribe_to_run.(run_id)
          :ok

        _ ->
          :skip
      end
    end
  rescue
    _ -> :skip
  end

  def submit_before_new(
        _state,
        _inbound,
        _scope,
        _session_key,
        _chat_id,
        _thread_id,
        _user_msg_id,
        _callbacks
      ),
      do: :skip

  @spec reflection_session_key(term()) :: binary()
  def reflection_session_key(session_key) when is_binary(session_key),
    do: session_key <> ":new_reflection"

  def reflection_session_key(_), do: "telegram:new_reflection"

  @spec format_run_history_transcript(list(), keyword()) :: binary()
  def format_run_history_transcript(history, opts) when is_list(history) do
    max_chars = Keyword.get(opts, :max_chars, 12_000)

    text =
      history
      |> Enum.reverse()
      |> Enum.map(&format_run_history_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.trim()

    if byte_size(text) > max_chars,
      do: String.slice(text, byte_size(text) - max_chars, max_chars),
      else: text
  rescue
    _ -> ""
  end

  def format_run_history_transcript(_history, _opts), do: ""

  @spec memory_reflection_prompt(binary()) :: binary()
  def memory_reflection_prompt(transcript) when is_binary(transcript) do
    """
    Before we start a new session, review the recent conversation transcript below.

    Task:
    - Record any durable, re-usable memories or learnings (preferences, recurring context, decisions, project facts, ongoing tasks) using the available memory workflow/tools.
    - If there is nothing worth saving, do not invent anything; just respond with "No memories to record."
    - Do not include private/secret data in durable memory.
    - In your final response, be brief (1-2 sentences) and do not paste the memories verbatim.

    Transcript (most recent portion):
    #{transcript}
    """
    |> String.trim()
  end

  defp format_run_history_entry({_run_id, data}) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    prompt = summary[:prompt] || summary["prompt"] || ""
    completed = summary[:completed] || summary["completed"] || %{}
    answer = if is_map(completed), do: completed[:answer] || completed["answer"] || "", else: ""
    prompt = prompt |> to_string() |> String.trim()
    answer = answer |> to_string() |> String.trim()

    cond do
      prompt == "" and answer == "" -> ""
      answer == "" -> "User:\n#{prompt}"
      true -> "User:\n#{prompt}\n\nAssistant:\n#{answer}"
    end
  rescue
    _ -> ""
  end

  defp format_run_history_entry(_), do: ""
end
