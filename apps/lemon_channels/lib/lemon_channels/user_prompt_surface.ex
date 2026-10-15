defmodule LemonChannels.UserPromptSurface do
  @moduledoc """
  Volatile, run-bound Telegram/Discord question surface. Registration precedes
  router submission, so tools see a surface even on the first turn. Queued runs
  retain their own originating user; a later sender never takes over a question.
  All answer transitions are serialized here and consumed by the agent prompt
  port. Opaque per-question tokens bind buttons to the exact pending snapshot.
  """
  use GenServer

  alias LemonChannels.Adapters.Discord.StatusRenderer
  alias LemonChannels.RemoteApproval
  alias LemonCore.{AgentRuntime, Bus, Event}

  @deadline 300_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(request) do
    if request.meta[:channel_id] in ["telegram", "discord"] and
         is_binary(get_in(request.meta, [:sender, :id])) and
         get_in(request.meta, [:sender, :bot]) != true do
      call({:register, request})
    else
      :ok
    end
  end

  def release(run_id), do: call({:release, run_id})

  @doc "Called only after transport authorization/deduplication, before mention gating."
  def capture(inbound) do
    text = inbound.message[:text]
    meta = inbound.meta || %{}

    plain? =
      is_binary(text) and String.trim(text) != "" and byte_size(text) <= 4_000 and
        not String.starts_with?(String.trim_leading(text), "/") and
        Enum.all?(
          [:photo, :document, :voice, :video, :animation, :video_note],
          &is_nil(meta[&1])
        ) and meta[:attachments] in [nil, []]

    if plain?, do: call({:capture, inbound}), else: false
  end

  def answer(data, channel, account, peer, user) when is_binary(data),
    do: call({:answer, data, channel, account, peer, user})

  def answer(_, _, _, _, _), do: {:error, :expired}

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    :ok = Bus.subscribe("user_prompts")

    {:ok,
     %{
       runs: %{},
       prompts: %{},
       enqueue: Keyword.get(opts, :enqueue, &LemonChannels.Outbox.enqueue/1)
     }}
  end

  @impl true
  def handle_call({:register, request}, _from, state) do
    key = request.session_key
    :ok = Bus.subscribe(Bus.run_topic(request.run_id))

    result =
      AgentRuntime.call(
        :user_prompt_bind,
        [key, self(), true, [max_timeout_ms: @deadline]],
        {:error, :unavailable}
      )

    run = %{
      session_key: key,
      target: Map.take(request.meta, [:channel_id, :account_id, :peer]),
      user: request.meta.sender.id
    }

    {:reply, result, %{state | runs: Map.put(state.runs, request.run_id, run)}}
  end

  def handle_call({:release, run}, _from, state), do: {:reply, :ok, remove_run(state, run)}

  def handle_call({:capture, inbound}, _from, state) do
    matches =
      Enum.filter(state.prompts, fn {_id, prompt} ->
        matches?(
          prompt,
          inbound.channel_id,
          inbound.account_id,
          inbound.peer,
          (inbound.sender || %{})[:id]
        ) and live?(prompt)
      end)

    # Multiple forked sessions in one conversation must not guess which question
    # an unaddressed message answers. Buttons remain available in this case.
    case matches do
      [{id, prompt}] ->
        {result, state} =
          advance(state, id, prompt, %{
            "q#{prompt.index}__other" => String.trim(inbound.message.text)
          })

        {:reply, result == :ok, state}

      [] ->
        {:reply, false, state}

      [{_, prompt} | _] ->
        _ =
          RemoteApproval.enqueue(
            prompt.target,
            "More than one question is waiting for you here. Please use the question's buttons.",
            %{plain_text: true},
            enqueue: state.enqueue
          )

        {:reply, true, state}
    end
  end

  def handle_call({:answer, data, channel, account, peer, user}, _from, state) do
    with ["ask", token, action] <- String.split(data, ":"),
         {id, prompt} <- Enum.find(state.prompts, fn {_, p} -> p.token == token end),
         true <- live?(prompt) do
      if matches?(prompt, channel, account, peer, user) do
        {result, state} = act(state, id, prompt, action)
        {:reply, result, state}
      else
        {:reply, {:error, :wrong_user}, state}
      end
    else
      _ -> {:reply, {:error, :expired}, state}
    end
  end

  @impl true
  def handle_info(%Event{type: :user_prompt_requested, payload: payload}, state) do
    key = payload["sessionKey"]

    case state.runs[payload["runId"]] do
      %{session_key: ^key} = run ->
        id = payload["promptId"]

        if Map.has_key?(state.prompts, id) do
          {:noreply, state}
        else
          prompt =
            Map.merge(run, %{
              public: payload,
              index: 0,
              content: %{},
              selected: [],
              token: token()
            })

          state = put_in(state.prompts[id], prompt)
          {:noreply, render(state, id, prompt)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(%Event{type: :user_prompt_resolved, payload: payload}, state) do
    state = %{state | prompts: Map.delete(state.prompts, payload["promptId"])}

    state =
      if payload["status"] == "timed_out", do: remove_run(state, payload["runId"]), else: state

    {:noreply, state}
  end

  def handle_info(%Event{type: type, meta: meta}, state)
      when type in [:run_completed, :run_failed],
      do: {:noreply, remove_run(state, meta[:run_id] || meta["run_id"])}

  def handle_info(_, state), do: {:noreply, state}

  defp act(state, id, prompt, action) when action in ["decline", "cancel"] do
    result = resolve(prompt, %{"action" => action})
    {result, %{state | prompts: Map.delete(state.prompts, id)}}
  end

  defp act(state, id, prompt, "done") do
    if prompt.selected == [] do
      {{:error, :empty}, state}
    else
      advance(state, id, prompt, %{"q#{prompt.index}" => prompt.selected})
    end
  end

  defp act(state, id, prompt, action) do
    question = Enum.at(prompt.public["questions"], prompt.index)

    with {index, ""} <- Integer.parse(action),
         true <- index >= 0,
         %{"label" => label} <- Enum.at(question["options"], index) do
      if question["multi"] do
        selected =
          if label in prompt.selected,
            do: List.delete(prompt.selected, label),
            else: prompt.selected ++ [label]

        prompt = %{prompt | selected: selected}
        state = put_in(state.prompts[id], prompt)
        {:ok, render(state, id, prompt)}
      else
        advance(state, id, prompt, %{"q#{prompt.index}" => label})
      end
    else
      _ -> {{:error, :expired}, state}
    end
  end

  defp advance(state, id, prompt, answer) do
    content = Map.merge(prompt.content, answer)

    if prompt.index + 1 == length(prompt.public["questions"]) do
      result = resolve(prompt, %{"action" => "accept", "content" => content})
      {result, %{state | prompts: Map.delete(state.prompts, id)}}
    else
      prompt = %{prompt | index: prompt.index + 1, content: content, selected: [], token: token()}
      state = put_in(state.prompts[id], prompt)
      {:ok, render(state, id, prompt)}
    end
  end

  defp render(state, id, prompt) do
    question = Enum.at(prompt.public["questions"], prompt.index)

    text =
      "Question #{prompt.index + 1}/#{length(prompt.public["questions"])}\n" <>
        question_text(question["question"], prompt.target.channel_id) <>
        "\n\nChoose a button or send your own answer as your next plain message here. /commands are not answers."

    options =
      Enum.with_index(question["options"], fn option, index ->
        label =
          if option["label"] in prompt.selected,
            do: "✓ " <> option["label"],
            else: option["label"]

        {display(label, 30), Integer.to_string(index)}
      end)

    options =
      options ++
        if(question["multi"], do: [{"Done selecting", "done"}], else: []) ++
        [{"Decline", "decline"}, {"Cancel", "cancel"}]

    callback = fn action -> "ask:#{prompt.token}:#{action}" end

    meta =
      if prompt.target.channel_id == "telegram" do
        %{
          reply_markup: %{
            "inline_keyboard" =>
              Enum.map(options, fn {label, action} ->
                [%{"text" => label, "callback_data" => callback.(action)}]
              end)
          },
          plain_text: true
        }
      else
        %{
          components:
            options
            |> Enum.map(fn {label, action} -> StatusRenderer.button(label, callback.(action)) end)
            |> Enum.chunk_every(5)
            |> Enum.map(&StatusRenderer.action_row/1)
        }
      end

    case RemoteApproval.enqueue(prompt.target, text, meta, enqueue: state.enqueue) do
      :ok ->
        state

      _ ->
        _ = resolve(prompt, %{"action" => "cancel"})
        %{state | prompts: Map.delete(state.prompts, id)}
    end
  end

  defp resolve(prompt, response),
    do:
      AgentRuntime.call(
        :user_prompt_resolve,
        [prompt.public["promptId"], prompt.session_key, prompt.public["runId"], response, self()],
        {:error, :expired}
      )

  defp remove_run(state, id) do
    case Map.pop(state.runs, id) do
      {nil, _} ->
        state

      {run, runs} ->
        _ = Bus.unsubscribe(Bus.run_topic(id))

        if not Enum.any?(runs, fn {_, r} -> r.session_key == run.session_key end),
          do:
            AgentRuntime.call(
              :user_prompt_bind,
              [run.session_key, self(), false],
              {:error, :unavailable}
            )

        prompts = Map.reject(state.prompts, fn {_, p} -> p.public["runId"] == id end)
        %{state | runs: runs, prompts: prompts}
    end
  end

  defp matches?(prompt, channel, account, peer, user),
    do:
      prompt.target.channel_id == channel and prompt.target.account_id == account and
        prompt.target.peer == peer and is_binary(user) and prompt.user == user

  defp live?(prompt),
    do:
      is_integer(prompt.public["expiresAtMs"]) and
        prompt.public["expiresAtMs"] > System.system_time(:millisecond)

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp question_text(text, "discord") do
    text
    |> display(800)
    |> String.replace(~r/[\\`*_{}\[\]()#+.!>|~\-]/u, fn char -> "\\" <> char end)
  end

  defp question_text(text, _channel), do: display(text, 1_200)

  defp display(text, max_bytes) do
    text = String.replace(text, ~r/[\x00-\x1f\x7f]/u, " ")

    if byte_size(text) <= max_bytes,
      do: text,
      else: trim_invalid_utf8(binary_part(text, 0, max_bytes)) <> "…"
  end

  defp trim_invalid_utf8(text) do
    if String.valid?(text),
      do: text,
      else: trim_invalid_utf8(binary_part(text, 0, byte_size(text) - 1))
  end
end
