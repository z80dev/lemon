defmodule LemonControlPlane.SessionModelTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.SessionModel

  defp fresh_key, do: "session_#{System.unique_integer([:positive])}"

  describe "override/1" do
    test "returns the session's stored model and nothing else" do
      key = fresh_key()
      LemonCore.PolicyStore.put_session(key, %{model: "gpt-5.4"})

      assert SessionModel.override(key) == "gpt-5.4"

      LemonCore.PolicyStore.delete_session(key)
    end

    test "is nil for a session that pinned nothing" do
      assert SessionModel.override(fresh_key()) == nil
    end

    test "is nil rather than raising for a missing or blank key" do
      assert SessionModel.override(nil) == nil
      assert SessionModel.override("") == nil
    end
  end

  describe "overrides/1" do
    test "reports each pinned value verbatim" do
      key = fresh_key()

      LemonCore.PolicyStore.put_session(key, %{
        model: "claude-sonnet-4-20250514",
        thinking_level: :high
      })

      assert %{
               model: "claude-sonnet-4-20250514",
               thinking_level: "high"
             } = SessionModel.overrides(key)

      LemonCore.PolicyStore.delete_session(key)
    end
  end

  describe "describe/1" do
    test "fills in provider and context window from the model catalog" do
      described = SessionModel.describe("claude-sonnet-4-20250514")

      assert described["model"] == "claude-sonnet-4-20250514"
      assert described["provider"] == "anthropic"
      assert is_integer(described["contextWindow"]) and described["contextWindow"] > 0
    end

    test "strips a provider prefix before looking the id up" do
      described = SessionModel.describe("anthropic:claude-sonnet-4-20250514")

      assert described["provider"] == "anthropic"
      # The id is echoed as given — the client asked about that string.
      assert described["model"] == "anthropic:claude-sonnet-4-20250514"
      assert is_integer(described["contextWindow"])
    end

    test "keeps an unknown id and takes its provider from the prefix" do
      described = SessionModel.describe("acme:some-unreleased-model")

      assert described["model"] == "acme:some-unreleased-model"
      assert described["provider"] == "acme"
      assert described["contextWindow"] == nil
    end

    test "is all-nil for a blank id" do
      assert %{"model" => nil, "provider" => nil, "contextWindow" => nil} =
               SessionModel.describe("  ")
    end
  end

  describe "resolve/2" do
    test "a session override wins and is labelled as such" do
      key = fresh_key()
      LemonCore.PolicyStore.put_session(key, %{model: "claude-sonnet-4-20250514"})

      resolved = SessionModel.resolve(key)

      assert resolved["model"] == "claude-sonnet-4-20250514"
      assert resolved["provider"] == "anthropic"
      assert resolved["modelSource"] == "session"
      assert is_integer(resolved["contextWindow"])

      LemonCore.PolicyStore.delete_session(key)
    end

    test "carries thinking level with fixed native provenance" do
      key = fresh_key()

      LemonCore.PolicyStore.put_session(key, %{
        model: "gpt-5.4",
        thinking_level: "medium"
      })

      resolved = SessionModel.resolve(key)

      assert resolved["thinkingLevel"] == "medium"
      assert resolved["engine"] == "lemon"
      refute Map.has_key?(resolved, "preferredEngine")

      LemonCore.PolicyStore.delete_session(key)
    end

    test "falls back to the config default and says so" do
      resolved = SessionModel.resolve(fresh_key())

      # A daemon with no configured default legitimately has no answer; when it has one,
      # the source must not claim the session pinned it.
      assert resolved["modelSource"] in [nil, "default"]
      refute resolved["modelSource"] == "session"
    end

    test "never raises on a nil session key" do
      assert is_map(SessionModel.resolve(nil))
    end
  end

  describe "channel /model preferences" do
    alias LemonChannels.Adapters.Discord.ModelPolicyAdapter, as: DiscordModels
    alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter, as: TelegramModels
    alias LemonCore.{PolicyStore, SessionKey}

    defp channel_session(channel, chat_id, thread_id) do
      key =
        SessionKey.channel_peer(%{
          agent_id: "default",
          channel_id: channel,
          account_id: "default",
          peer_kind: :group,
          peer_id: to_string(chat_id),
          thread_id: thread_id && to_string(thread_id)
        })

      on_exit(fn ->
        PolicyStore.delete_session(key)

        for thread <- [thread_id, nil],
            do:
              PolicyStore.delete_chat(
                {channel, "default", to_string(chat_id), thread && to_string(thread)}
              )
      end)

      key
    end

    for {channel, adapter} <- [{"telegram", TelegramModels}, {"discord", DiscordModels}] do
      test "a #{channel} session override is the control plane's session model" do
        adapter = unquote(adapter)
        chat_id = System.unique_integer([:positive])
        key = channel_session(unquote(channel), chat_id, nil)

        :ok = adapter.put_session_model_override(key, "#{unquote(channel)}-session-model")

        assert SessionModel.override(key) == "#{unquote(channel)}-session-model"
        assert %{"modelSource" => "session"} = resolved = SessionModel.resolve(key)
        assert resolved["model"] == "#{unquote(channel)}-session-model"
      end

      test "a #{channel} chat default reaches the control plane for that chat's thread sessions" do
        adapter = unquote(adapter)
        chat_id = System.unique_integer([:positive])
        thread_id = System.unique_integer([:positive])
        key = channel_session(unquote(channel), chat_id, thread_id)

        # The channel's own route and the session key name the same chat route.
        assert adapter.route_for("default", chat_id, thread_id) == PolicyStore.chat_route(key)

        :ok = adapter.put_default_model_preference("default", chat_id, nil, "chat-model")
        :ok = adapter.put_default_thinking_preference("default", chat_id, thread_id, "high")

        assert SessionModel.override(key) == nil

        assert %{"model" => "chat-model", "modelSource" => "chat", "thinkingLevel" => "high"} =
                 SessionModel.resolve(key)

        :ok = adapter.put_session_model_override(key, "pinned-model")

        assert %{"model" => "pinned-model", "modelSource" => "session"} =
                 SessionModel.resolve(key)
      end
    end
  end

  describe "provider_for/1" do
    test "answers with just the provider" do
      assert SessionModel.provider_for("claude-sonnet-4-20250514") == "anthropic"
      assert SessionModel.provider_for(nil) == nil
    end
  end
end
