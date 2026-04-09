defmodule LemonChannels.Adapters.Telegram.TransportCancelTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Telegram.{ResumeIndexStore, StateStore}
  alias LemonCore.ModelPolicy

  defmodule CancelTestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def abort(session_key, reason) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:abort_session, session_key, reason})
      end

      :ok
    end

    def abort_run(run_id, reason) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:abort_run, run_id, reason})
      end

      :ok
    end
  end

  defmodule CancelMockAPI do
    @updates_key {__MODULE__, :updates}
    @pid_key {__MODULE__, :pid}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register_test(pid), do: :persistent_term.put(@pid_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      updates = :persistent_term.get(@updates_key, [])

      case updates do
        [next | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [next]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
      notify({:send_message, chat_id, text, reply_to_or_opts, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      notify({:edit_message_text, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      notify({:delete_message, chat_id, message_id})
      {:ok, %{"ok" => true}}
    end

    def answer_callback_query(_token, callback_id, opts \\ %{}) do
      notify({:answer_callback, callback_id, opts})
      {:ok, %{"ok" => true}}
    end

    def set_message_reaction(_token, chat_id, message_id, emoji, _opts \\ %{}) do
      notify({:set_message_reaction, chat_id, message_id, emoji})
      {:ok, %{"ok" => true}}
    end

    defp notify(msg) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, msg)
      end

      :ok
    end
  end

  setup do
    stop_transport()

    ModelPolicy.list()
    |> Enum.each(fn {route, _policy} -> ModelPolicy.clear(route) end)

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_config_env = Application.get_env(:lemon_channels, :gateway)
    old_openai_api_key = System.get_env("OPENAI_API_KEY")
    old_default_provider = System.get_env("LEMON_DEFAULT_PROVIDER")

    :persistent_term.put({CancelTestRouter, :pid}, self())
    CancelMockAPI.register_test(self())
    LemonCore.RouterBridge.configure(router: CancelTestRouter)
    set_bindings([])
    System.put_env("OPENAI_API_KEY", "test-openai-key")
    System.put_env("LEMON_DEFAULT_PROVIDER", "openai")

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({CancelMockAPI, :updates})
      :persistent_term.erase({CancelMockAPI, :pid})
      :persistent_term.erase({CancelTestRouter, :pid})
      restore_router_bridge(old_router_bridge)
      restore_gateway_config_env(old_gateway_config_env)
      restore_env_var("OPENAI_API_KEY", old_openai_api_key)
      restore_env_var("LEMON_DEFAULT_PROVIDER", old_default_provider)
    end)

    :ok
  end

  test "progress '👀' reaction is set on user message" do
    chat_id = 333_001
    user_msg_id = 1234
    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    # Should set 👀 reaction on the user's message
    assert_receive {:set_message_reaction, ^chat_id, ^user_msg_id, "👀"}, 400
  end

  test "cancel callback cancels the run mapped to the progress message id" do
    chat_id = 333_002
    progress_msg_id = 555
    cb_id = "cb-1"

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    _ = ResumeIndexStore.put_session("default", chat_id, nil, progress_msg_id, session_key)

    CancelMockAPI.set_updates([
      cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:abort_session, ^session_key, :user_requested}, 400
  end

  test "cancel callback with a run id cancels the run registered under that id" do
    chat_id = 333_003
    progress_msg_id = 777
    cb_id = "cb-2"
    run_id = "run_#{System.unique_integer([:positive])}"

    CancelMockAPI.set_updates([
      cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel:" <> run_id)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:abort_run, ^run_id, :user_requested}, 400
  end

  test "/model opens provider picker and does not route inbound" do
    chat_id = 333_004
    msg_id = 1_200

    CancelMockAPI.set_updates([message_update(chat_id, msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, text, opts, _parse_mode}, 500
    assert text =~ "Model picker"
    keyboard = get_in(opts, ["reply_markup", "keyboard"])
    assert is_list(keyboard)
    assert keyboard != []
    assert get_in(opts, ["reply_markup", "inline_keyboard"]) == nil
    refute_receive {:inbound, _msg}, 250
  end

  test "/model reply-keyboard flow can set a session model override" do
    chat_id = 333_005
    user_msg_id = 1_300

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    assert is_binary(provider_choice)
    refute provider_choice in ["Close", "<< Prev", "Next >>"]

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, provider_text, model_opts, _parse_mode}, 500
    assert provider_text =~ "Provider: #{provider_choice}"

    model_choice =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    assert is_binary(model_choice)
    refute model_choice in ["< Back", "Close", "<< Prev", "Next >>"]

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 2, model_choice)
    ])

    assert_receive {:send_message, ^chat_id, scope_text, _scope_opts, _parse_mode}, 500
    assert scope_text =~ "Selected model:"
    assert scope_text =~ "Apply to:"

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 3, "This session")
    ])

    assert_receive {:send_message, ^chat_id, text, finish_opts, _parse_mode}, 500
    assert text =~ "Model set to"
    assert get_in(finish_opts, ["reply_markup", "remove_keyboard"]) == true

    stored = StateStore.get_session_model(session_key)
    assert is_binary(stored)
    assert String.starts_with?(stored, provider_choice <> ":")

    refute_receive {:inbound, _msg}, 200
  end

  test "/model reply-keyboard flow accepts follow-up selections when Telegram sender ids are integers" do
    chat_id = 333_005_1
    user_msg_id = 1_301

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, provider_text, _model_opts, _parse_mode}, 500
    assert provider_text =~ "Provider: #{provider_choice}"
    refute_receive {:inbound, _msg}, 200
  end

  test "/model reply-keyboard flow accepts raw model ids and provider-qualified model specs" do
    chat_id = 333_005_15
    user_msg_id = 1_301_5

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, model_opts, _parse_mode}, 500

    model_choice =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    [_, model_id] = Regex.run(~r/\(([^()]+)\)\s*$/, model_choice)

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 2, model_id)
    ])

    assert_receive {:send_message, ^chat_id, scope_text, _scope_opts, _parse_mode}, 500
    assert scope_text =~ "Selected model:"

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id + 3, "< Back")])

    assert_receive {:send_message, ^chat_id, _provider_text, _model_opts_again, _parse_mode}, 500

    provider_model_spec = provider_choice <> ":" <> model_id

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 4, provider_model_spec)
    ])

    assert_receive {:send_message, ^chat_id, scope_text_again, _scope_opts, _parse_mode}, 500
    assert scope_text_again =~ "Selected model:"
    refute_receive {:inbound, _msg}, 200
  end

  test "/model invalid provider text stays inside the picker flow" do
    chat_id = 333_005_2
    user_msg_id = 1_302

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, _opts, _parse_mode}, 500

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, "openai-codex")
    ])

    assert_receive {:send_message, ^chat_id, text, opts, _parse_mode}, 500
    assert text =~ "Unknown provider selection"
    assert text =~ "Choose a provider:"
    assert is_list(get_in(opts, ["reply_markup", "keyboard"]))
    refute_receive {:inbound, _msg}, 200
  end

  test "/model reopens the picker when follow-up sender key does not match" do
    chat_id = 333_005_21
    user_msg_id = 1_302_1

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, _opts, _parse_mode}, 500

    CancelMockAPI.set_updates([
      message_update_from(chat_id, user_msg_id + 1, "openai-codex", 100)
    ])

    assert_receive {:send_message, ^chat_id, text, opts, _parse_mode}, 500
    assert text =~ "Model picker"
    assert text =~ "Choose a provider:"
    assert is_list(get_in(opts, ["reply_markup", "keyboard"]))
    refute_receive {:inbound, _msg}, 200
  end

  test "/model invalid model text stays inside the picker flow" do
    chat_id = 333_005_3
    user_msg_id = 1_303

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, _model_opts, _parse_mode}, 500

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 2, "not-a-real-model")
    ])

    assert_receive {:send_message, ^chat_id, text, reply_opts, _parse_mode}, 500
    assert text =~ "Unknown model selection"
    assert text =~ "Choose a model:"
    assert is_list(get_in(reply_opts, ["reply_markup", "keyboard"]))
    refute_receive {:inbound, _msg}, 200
  end

  test "/model minimax picker omits the broken highspeed variant" do
    chat_id = 333_005_31
    user_msg_id = 1_333_1

    System.put_env("MINIMAX_API_KEY", "test-minimax-key")

    on_exit(fn ->
      System.delete_env("MINIMAX_API_KEY")
    end)

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    minimax_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.flatten()
      |> Enum.find(fn
        %{"text" => text} -> String.contains?(String.downcase(text), "minimax")
        _ -> false
      end)
      |> Map.fetch!("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, minimax_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, model_opts, _parse_mode}, 500

    model_texts =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "text"))

    refute Enum.any?(model_texts, &String.contains?(&1, "MiniMax-M2.7-highspeed"))
  end

  test "/model google picker omits dead direct ids and prefers custom-tools preview" do
    chat_id = 333_005_32
    user_msg_id = 1_333_2

    System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", "test-google-key")

    on_exit(fn ->
      System.delete_env("GOOGLE_GENERATIVE_AI_API_KEY")
    end)

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    google_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.flatten()
      |> Enum.find(fn
        %{"text" => text} -> String.contains?(String.downcase(text), "google")
        _ -> false
      end)
      |> Map.fetch!("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, google_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, model_opts, _parse_mode}, 500

    model_texts =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "text"))

    refute Enum.any?(model_texts, &String.contains?(&1, "Gemini 3.1 Pro (gemini-3.1-pro)"))
    assert hd(model_texts) =~ "Gemini 3.1 Pro Preview (Custom Tools)"
  end

  test "/model does not advertise google vertex when only direct google credentials exist" do
    chat_id = 333_005_33
    user_msg_id = 1_333_3

    System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", "test-google-key")

    on_exit(fn ->
      System.delete_env("GOOGLE_GENERATIVE_AI_API_KEY")
    end)

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_texts =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "text"))

    refute Enum.any?(provider_texts, &String.contains?(String.downcase(&1), "vertex"))
  end

  test "/model invalid scope text stays inside the picker flow" do
    chat_id = 333_005_4
    user_msg_id = 1_304

    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, model_opts, _parse_mode}, 500

    model_choice =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 2, model_choice)
    ])

    assert_receive {:send_message, ^chat_id, _scope_text, _scope_opts, _parse_mode}, 500

    CancelMockAPI.set_updates([
      message_update(chat_id, user_msg_id + 3, "tomorrow only")
    ])

    assert_receive {:send_message, ^chat_id, text, reply_opts, _parse_mode}, 500
    assert text =~ "Choose one of the scope buttons."
    assert text =~ "Apply to:"
    assert is_list(get_in(reply_opts, ["reply_markup", "keyboard"]))
    refute_receive {:inbound, _msg}, 200
  end

  test "/model reply-keyboard future scope writes a chat-wide default even inside a topic" do
    chat_id = 333_006
    topic_id = 9_001
    user_msg_id = 1_400

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    CancelMockAPI.set_updates([topic_message_update(chat_id, topic_id, user_msg_id, "/model")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text, opts, _parse_mode}, 500

    provider_choice =
      opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      topic_message_update(chat_id, topic_id, user_msg_id + 1, provider_choice)
    ])

    assert_receive {:send_message, ^chat_id, _provider_text, model_opts, _parse_mode}, 500

    model_choice =
      model_opts
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      topic_message_update(chat_id, topic_id, user_msg_id + 2, model_choice)
    ])

    assert_receive {:send_message, ^chat_id, _scope_text, _scope_opts, _parse_mode}, 500

    CancelMockAPI.set_updates([
      topic_message_update(chat_id, topic_id, user_msg_id + 3, "All future sessions")
    ])

    assert_receive {:send_message, ^chat_id, text, finish_opts, _parse_mode}, 500
    assert text =~ "Default model set to"
    assert get_in(finish_opts, ["reply_markup", "remove_keyboard"]) == true

    stored = StateStore.get_session_model(session_key)
    assert is_binary(stored)

    chat_route = ModelPolicyAdapter.route_for("default", chat_id, nil)
    topic_route = ModelPolicyAdapter.route_for("default", chat_id, topic_id)

    assert %{model_id: ^stored} = ModelPolicy.get(chat_route)
    assert nil == ModelPolicy.get(topic_route)
    refute_receive {:inbound, _msg}, 200
  end

  test "/model callback future scope writes a chat-wide default even inside a topic" do
    chat_id = 333_007
    topic_id = 9_002
    message_id = 1_500

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    CancelMockAPI.set_updates([
      model_callback_update(chat_id, topic_id, "cb-1", message_id, "lemon:model:providers:0")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:edit_message_text, ^chat_id, ^message_id, picker_text, picker_opts}, 500
    assert picker_text =~ "Model picker"
    assert_receive {:answer_callback, "cb-1", %{"text" => "Updated"}}, 500

    provider_callback =
      picker_opts
      |> get_in(["reply_markup", "inline_keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("callback_data")

    CancelMockAPI.set_updates([
      model_callback_update(chat_id, topic_id, "cb-2", message_id, provider_callback)
    ])

    assert_receive {:edit_message_text, ^chat_id, ^message_id, provider_text, provider_opts}, 500
    assert provider_text =~ "Provider:"
    assert_receive {:answer_callback, "cb-2", %{"text" => "Updated"}}, 500

    choose_callback =
      provider_opts
      |> get_in(["reply_markup", "inline_keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("callback_data")

    CancelMockAPI.set_updates([
      model_callback_update(chat_id, topic_id, "cb-3", message_id, choose_callback)
    ])

    assert_receive {:edit_message_text, ^chat_id, ^message_id, scope_text, scope_opts}, 500
    assert scope_text =~ "Selected model:"
    assert_receive {:answer_callback, "cb-3", %{"text" => "Select scope"}}, 500

    future_callback =
      scope_opts
      |> get_in(["reply_markup", "inline_keyboard"])
      |> Enum.find_value(fn row ->
        Enum.find_value(row, fn button ->
          if button["text"] == "All future sessions", do: button["callback_data"], else: nil
        end)
      end)

    assert is_binary(future_callback)

    CancelMockAPI.set_updates([
      model_callback_update(chat_id, topic_id, "cb-4", message_id, future_callback)
    ])

    assert_receive {:edit_message_text, ^chat_id, ^message_id, saved_text, saved_opts}, 500
    assert saved_text =~ "Default model set to"
    assert get_in(saved_opts, ["reply_markup", "inline_keyboard"]) == []
    assert_receive {:answer_callback, "cb-4", %{"text" => "Saved"}}, 500

    stored = StateStore.get_session_model(session_key)
    assert is_binary(stored)

    chat_route = ModelPolicyAdapter.route_for("default", chat_id, nil)
    topic_route = ModelPolicyAdapter.route_for("default", chat_id, topic_id)

    assert %{model_id: ^stored} = ModelPolicy.get(chat_route)
    assert nil == ModelPolicy.get(topic_route)
  end

  test "/model reply-keyboard flows remain independent across two topics in the same chat" do
    chat_id = 333_008
    topic_a = 9_101
    topic_b = 9_102
    msg_a = 1_601
    msg_b = 1_701

    CancelMockAPI.set_updates([
      topic_message_update(chat_id, topic_a, msg_a, "/model"),
      topic_message_update(chat_id, topic_b, msg_b, "/model")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, _text_a, opts_a, _parse_mode}, 500
    assert get_in(opts_a, ["message_thread_id"]) == topic_a

    assert_receive {:send_message, ^chat_id, _text_b, opts_b, _parse_mode}, 500
    assert get_in(opts_b, ["message_thread_id"]) == topic_b

    provider_a =
      opts_a
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    provider_b =
      opts_b
      |> get_in(["reply_markup", "keyboard"])
      |> List.first()
      |> List.first()
      |> Map.get("text")

    CancelMockAPI.set_updates([
      topic_message_update(chat_id, topic_a, msg_a + 1, provider_a),
      topic_message_update(chat_id, topic_b, msg_b + 1, provider_b)
    ])

    assert_receive {:send_message, ^chat_id, text_a, model_opts_a, _parse_mode}, 500
    assert text_a =~ "Provider: #{provider_a}"
    assert get_in(model_opts_a, ["message_thread_id"]) == topic_a

    assert_receive {:send_message, ^chat_id, text_b, model_opts_b, _parse_mode}, 500
    assert text_b =~ "Provider: #{provider_b}"
    assert get_in(model_opts_b, ["message_thread_id"]) == topic_b

    refute_receive {:inbound, _msg}, 200
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: CancelMockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
  end

  defp message_update(chat_id, message_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp message_update_from(chat_id, message_id, text, from_id) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => from_id, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp topic_message_update(chat_id, topic_id, message_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "message_thread_id" => topic_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp cancel_callback_update(chat_id, cb_id, message_id, data) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => cb_id,
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "data" => data,
        "message" => %{
          "message_id" => message_id,
          "chat" => %{"id" => chat_id, "type" => "private"}
        }
      }
    }
  end

  defp model_callback_update(chat_id, topic_id, cb_id, message_id, data) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => cb_id,
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "data" => data,
        "message" => %{
          "message_id" => message_id,
          "message_thread_id" => topic_id,
          "chat" => %{"id" => chat_id, "type" => "private"}
        }
      }
    }
  end

  defp set_bindings(bindings) do
    cfg =
      case Application.get_env(:lemon_channels, :gateway) do
        map when is_map(map) -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    Application.put_env(:lemon_channels, :gateway, Map.put(cfg, :bindings, bindings))
  end

  defp restore_gateway_config_env(nil) do
    Application.delete_env(:lemon_channels, :gateway)
  end

  defp restore_gateway_config_env(env) do
    Application.put_env(:lemon_channels, :gateway, env)
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp restore_env_var(name, nil), do: System.delete_env(name)
  defp restore_env_var(name, value), do: System.put_env(name, value)

  defp stop_transport do
    if pid = Process.whereis(Elixir.LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
