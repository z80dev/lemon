defmodule LemonChannels.UserPromptSurfaceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.UserPrompt
  alias CodingAgent.Tools.Ask
  alias LemonChannels.Adapters.Telegram.Outbound
  alias LemonChannels.Adapters.Telegram.Transport.{CallbackHandler, InboundContext, Pipeline}
  alias LemonChannels.{RunRequestBuilder, UserPromptSurface}
  alias LemonCore.{Bus, Event, InboundMessage}

  defmodule API do
    def send_message(_, chat_id, text, opts, mode) do
      send(self(), {:sent, chat_id, text, opts, mode})
      {:ok, %{"message_id" => 123}}
    end

    def answer_callback_query(_, id, opts) do
      send(self(), {:callback_answer, id, opts["text"]})
      :ok
    end
  end

  setup do
    original = :sys.get_state(UserPromptSurface).enqueue
    owner = self()

    :sys.replace_state(
      UserPromptSurface,
      &%{
        &1
        | enqueue: fn payload ->
            send(owner, {:rendered, payload})
            {:ok, make_ref()}
          end
      }
    )

    :ok = Bus.subscribe("user_prompts")
    on_exit(fn -> :sys.replace_state(UserPromptSurface, &%{&1 | enqueue: original}) end)
    :ok
  end

  test "Telegram renders bounded plain questions and binds choices to originating user/chat/thread" do
    {request, inbound} = register("telegram")
    question = question(String.duplicate("<untrusted>*", 200))
    task = ask(request, [question])
    assert_receive {:rendered, payload}
    assert payload.meta.plain_text
    assert String.length(payload.content) < 1_600
    config_key = :"Elixir.LemonGateway.Config"
    previous = Application.get_env(:lemon_gateway, config_key)

    Application.put_env(
      :lemon_gateway,
      config_key,
      Map.put(previous || %{}, :telegram, %{
        account_id: "default",
        bot_token: "fake",
        api_mod: API,
        use_markdown: true
      })
    )

    on_exit(fn -> Application.put_env(:lemon_gateway, config_key, previous) end)
    assert {:ok, _} = Outbound.deliver(payload)
    assert_receive {:sent, -100, text, opts, nil}
    assert text == payload.content
    assert opts[:reply_markup] == payload.meta.reply_markup
    refute opts[:entities]
    [choice, _other_choice, decline, _cancel] = payload.meta.reply_markup["inline_keyboard"]
    data = hd(choice)["callback_data"]
    assert byte_size(data) <= 64
    assert hd(choice)["text"] == "A"

    cb = callback(data, inbound)
    state = telegram_state()
    CallbackHandler.handle_callback_query(state, put_in(cb, ["from", "id"], 99))
    assert_receive {:callback_answer, "cb", "Only the user who started this run may answer here."}
    assert Task.yield(task, 0) == nil
    CallbackHandler.handle_callback_query(state, put_in(cb, ["message", "message_thread_id"], 8))
    assert_receive {:callback_answer, "cb", "Only the user who started this run may answer here."}
    CallbackHandler.handle_callback_query(state, cb)
    assert_receive {:callback_answer, "cb", "Recorded"}
    result = Task.await(task)
    assert result.details.status == "answered"
    assert hd(result.details.results)["selectedOptions"] == ["A"]
    CallbackHandler.handle_callback_query(state, cb)
    assert_receive {:callback_answer, "cb", "expired"}
    assert String.ends_with?(hd(decline)["callback_data"], ":decline")
    finish(request)
  end

  test "Telegram free-text answer is consumed before ordinary submission, without needing a mention" do
    {request, inbound} = register("telegram")
    task = ask(request, [%{"id" => "text", "question" => "Explain", "options" => []}])
    assert_receive {:rendered, _}
    reply = %{inbound | message: %{id: "new-reply", text: "My actual answer"}}
    ctx = %InboundContext{kind: :message, raw_update: %{"message" => %{}}, inbound: reply}
    state = telegram_state() |> Map.merge(%{dedupe_ttl_ms: 60_000, allow_queue_override: false})
    {_state, actions} = Pipeline.run(ctx, state)
    refute Enum.any?(actions, &match?({:execute_inbound_message, _}, &1))
    assert hd(Task.await(task).details.results)["customInput"] == "My actual answer"
    finish(request)
  end

  test "free text ignores other users, other threads, commands and attachments" do
    {request, inbound} = register("telegram")
    task = ask(request, [question()])
    assert_receive {:rendered, _}
    refute UserPromptSurface.capture(%{inbound | sender: %{id: "99"}})
    refute UserPromptSurface.capture(%{inbound | peer: %{inbound.peer | thread_id: "8"}})
    refute UserPromptSurface.capture(%{inbound | message: %{text: "/cancel"}})
    refute UserPromptSurface.capture(%{inbound | meta: %{photo: %{file_id: "photo"}}})
    assert UserPromptSurface.capture(%{inbound | message: %{text: "Custom"}})
    assert hd(Task.await(task).details.results)["customInput"] == "Custom"
    finish(request)
  end

  test "deadlines return no answer and stale buttons expire; run end unbinds" do
    {request, inbound} = register("telegram")
    task = ask(request, [question()], 50)
    assert_receive {:rendered, payload}

    data =
      get_in(payload.meta, [:reply_markup, "inline_keyboard"])
      |> hd()
      |> hd()
      |> Map.fetch!("callback_data")

    result = Task.await(task)
    assert result.is_error
    assert result.details.status == "timed_out"
    refute Map.has_key?(result.details, :results)

    assert {:error, :expired} =
             UserPromptSurface.answer(data, "telegram", "default", inbound.peer, "42")

    finish(request)
    refute UserPrompt.bound?(request.session_key)
  end

  test "Discord renders option buttons and resolves only the originating member interaction" do
    {request, inbound} = register("discord")
    task = ask(request, [question()])
    assert_receive {:rendered, payload}
    [row] = payload.meta.components
    [button | _] = row.components
    assert button.type == 2
    assert button.label == "A"

    interaction = %{
      data: %{custom_id: button.custom_id},
      channel_id: 7,
      guild_id: 1,
      channel: %{parent_id: -100, thread_metadata: %{}},
      member: %{user: %{id: 42}}
    }

    handler = LemonChannels.Adapters.Discord.UserPrompt

    assert {:error, :wrong_user} =
             handler.handle(
               %{account_id: "default"},
               put_in(interaction, [:member, :user, :id], 99)
             )

    assert :ok = handler.handle(%{account_id: "default"}, interaction)
    assert hd(Task.await(task).details.results)["selectedOptions"] == ["A"]

    assert {:error, :expired} =
             UserPromptSurface.answer(button.custom_id, "discord", "default", inbound.peer, "42")

    finish(request)
  end

  test "multi-question forms support multiple selections and never choose on decline" do
    {request, inbound} = register("telegram")

    task =
      ask(request, [Map.put(question(), "multi", true), question() |> Map.put("id", "second")])

    assert_receive {:rendered, first}
    buttons = List.flatten(first.meta.reply_markup["inline_keyboard"])

    answer = fn index ->
      UserPromptSurface.answer(
        Enum.at(buttons, index)["callback_data"],
        "telegram",
        "default",
        inbound.peer,
        "42"
      )
    end

    assert {:error, :empty} = answer.(2)
    assert :ok = answer.(0)
    assert_receive {:rendered, _}
    assert :ok = answer.(1)
    assert_receive {:rendered, _}
    assert :ok = answer.(2)
    assert_receive {:rendered, second}
    assert {:error, :expired} = answer.(0)
    decline = second.meta.reply_markup["inline_keyboard"] |> Enum.at(2) |> hd()

    assert :ok =
             UserPromptSurface.answer(
               decline["callback_data"],
               "telegram",
               "default",
               inbound.peer,
               "42"
             )

    result = Task.await(task)
    assert result.details.status == "declined"
    refute Map.has_key?(result.details, :results)
    finish(request)
  end

  test "run completion cancels a pending question and removes the surface" do
    {request, _inbound} = register("telegram")
    task = ask(request, [question()])
    assert_receive {:rendered, _}

    Bus.broadcast(
      Bus.run_topic(request.run_id),
      Event.new(:run_completed, %{}, %{run_id: request.run_id})
    )

    result = Task.await(task)
    assert result.is_error
    refute UserPrompt.bound?(request.session_key)
  end

  test "a queued sender cannot take over the active run's prompt and answers consume once" do
    {request, inbound} = register("telegram")
    task = ask(request, [question()])
    assert_receive {:rendered, payload}

    queued = %{
      request
      | run_id: request.run_id <> "_queued",
        meta: Map.put(request.meta, :sender, %{id: "99", bot: false})
    }

    assert :ok = UserPromptSurface.register(queued)
    on_exit(fn -> UserPromptSurface.release(queued.run_id) end)

    data =
      payload.meta.reply_markup["inline_keyboard"] |> hd() |> hd() |> Map.fetch!("callback_data")

    assert {:error, :wrong_user} =
             UserPromptSurface.answer(data, "telegram", "default", inbound.peer, "99")

    assert {:error, :wrong_user} =
             UserPromptSurface.answer(data, "telegram", "other", inbound.peer, "42")

    assert {:error, :wrong_user} =
             UserPromptSurface.answer(
               data,
               "telegram",
               "default",
               %{inbound.peer | id: "-200"},
               "42"
             )

    results =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              UserPromptSurface.answer(data, "telegram", "default", inbound.peer, "42")
            end)

    assert Enum.sort(Enum.map(results, &Task.await/1)) == Enum.sort([:ok, {:error, :expired}])
    assert hd(Task.await(task).details.results)["selectedOptions"] == ["A"]
    finish(request)
    assert UserPrompt.bound?(request.session_key)
    finish(queued)
    refute UserPrompt.bound?(request.session_key)
  end

  test "ambiguous plain replies never start a new run or guess between forked prompts" do
    {request, inbound} = register("telegram")

    fork = %{
      request
      | run_id: request.run_id <> "_fork",
        session_key: request.session_key <> ":fork"
    }

    assert :ok = UserPromptSurface.register(fork)
    on_exit(fn -> UserPromptSurface.release(fork.run_id) end)
    first = ask(request, [question()])
    assert_receive {:rendered, _}
    second = ask(fork, [question()])
    assert_receive {:rendered, _}
    assert UserPromptSurface.capture(inbound)
    assert_receive {:rendered, notice}
    assert notice.content =~ "More than one question"
    assert Task.yield(first, 0) == nil
    assert Task.yield(second, 0) == nil
    finish(request)
    finish(fork)
    assert Task.await(first).is_error
    assert Task.await(second).is_error
  end

  defp register(channel) do
    id = System.unique_integer([:positive])

    inbound = %InboundMessage{
      channel_id: channel,
      account_id: "default",
      peer: %{kind: :group, id: "-100", thread_id: "7"},
      sender: %{id: "42", bot: false},
      message: %{id: "#{id}", text: "start", timestamp: 0, reply_to_id: nil},
      raw: %{},
      meta: %{}
    }

    request = %{RunRequestBuilder.from_inbound(inbound) | run_id: "run_test_#{id}"}
    assert :ok = UserPromptSurface.register(request)
    assert Ask.available?(session_key: request.session_key)
    on_exit(fn -> UserPromptSurface.release(request.run_id) end)
    {request, inbound}
  end

  defp ask(request, questions, timeout \\ nil) do
    params =
      if timeout,
        do: %{"questions" => questions, "timeout_ms" => timeout},
        else: %{"questions" => questions}

    task =
      Task.async(fn ->
        Ask.execute("ask", params, nil, nil,
          session_key: request.session_key,
          run_id: request.run_id
        )
      end)

    assert_receive %Event{type: :user_prompt_requested, payload: payload}
    assert payload["expiresAtMs"] - payload["requestedAtMs"] == (timeout || 300_000)
    task
  end

  defp question(text \\ "Choose"),
    do: %{
      "id" => "q",
      "question" => text,
      "options" => [%{"label" => "A"}, %{"label" => "B"}],
      "recommended" => 1
    }

  defp finish(request), do: assert(:ok == UserPromptSurface.release(request.run_id))

  defp telegram_state,
    do: %{
      account_id: "default",
      api_mod: API,
      token: "fake",
      allowed_chat_ids: [-100],
      deny_unbound_chats: false
    }

  defp callback(data, _inbound),
    do: %{
      "id" => "cb",
      "data" => data,
      "from" => %{"id" => 42},
      "message" => %{
        "message_id" => 123,
        "message_thread_id" => 7,
        "chat" => %{"id" => -100, "type" => "supergroup"}
      }
    }
end
