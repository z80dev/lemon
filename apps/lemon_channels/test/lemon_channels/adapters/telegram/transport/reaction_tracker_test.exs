defmodule LemonChannels.Adapters.Telegram.Transport.ReactionTrackerTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ReactionTracker
  alias LemonCore.Event

  # ---------------------------------------------------------------------------
  # Mock API modules
  # ---------------------------------------------------------------------------

  defmodule SuccessAPI do
    def set_message_reaction(_token, _chat_id, _msg_id, _emoji, _opts) do
      {:ok, %{"ok" => true}}
    end

    def send_message(_token, _chat_id, _text, _opts \\ nil, _parse \\ nil) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end
  end

  defmodule FailAPI do
    def set_message_reaction(_token, _chat_id, _msg_id, _emoji, _opts) do
      {:error, "reaction failed"}
    end
  end

  # ---------------------------------------------------------------------------
  # send_progress/4
  # ---------------------------------------------------------------------------

  describe "send_progress/4" do
    test "returns message_id on successful reaction" do
      state = base_state(api_mod: SuccessAPI)
      assert ReactionTracker.send_progress(state, 123, nil, 42) == 42
    end

    test "returns nil when reply_to_message_id is nil" do
      state = base_state(api_mod: SuccessAPI)
      assert ReactionTracker.send_progress(state, 123, nil, nil) == nil
    end

    test "returns nil when reply_to_message_id is not an integer" do
      state = base_state(api_mod: SuccessAPI)
      assert ReactionTracker.send_progress(state, 123, nil, "not_int") == nil
    end

    test "returns nil when API call fails" do
      state = base_state(api_mod: FailAPI)
      assert ReactionTracker.send_progress(state, 123, nil, 42) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # track_run/6
  # ---------------------------------------------------------------------------

  describe "track_run/6" do
    test "stores reaction run metadata in state" do
      state = base_state() |> Map.put(:reaction_runs, %{})
      session_key = "telegram:test:123"

      result = ReactionTracker.track_run(state, 42, session_key, 123, nil, 1)

      assert Map.has_key?(result.reaction_runs, session_key)
      run = result.reaction_runs[session_key]
      assert run.chat_id == 123
      assert run.user_msg_id == 1
      assert run.session_key == session_key
    end

    test "returns state unchanged when progress_msg_id is nil" do
      state = base_state() |> Map.put(:reaction_runs, %{})

      result = ReactionTracker.track_run(state, nil, "session_key", 123, nil, 1)
      assert result.reaction_runs == %{}
    end

    test "returns state unchanged when session_key is nil" do
      state = base_state() |> Map.put(:reaction_runs, %{})

      result = ReactionTracker.track_run(state, 42, nil, 123, nil, 1)
      assert result.reaction_runs == %{}
    end

    test "returns state unchanged when progress_msg_id is not an integer" do
      state = base_state() |> Map.put(:reaction_runs, %{})

      result = ReactionTracker.track_run(state, "not_int", "session_key", 123, nil, 1)
      assert result.reaction_runs == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_run_completed/3
  # ---------------------------------------------------------------------------

  describe "handle_run_completed/3" do
    test "removes session from reaction_runs on completion" do
      session_key = "telegram:test:123"

      state =
        base_state(api_mod: SuccessAPI)
        |> Map.put(:reaction_runs, %{
          session_key => %{
            chat_id: 123,
            thread_id: nil,
            user_msg_id: 42,
            session_key: session_key
          }
        })

      event = Event.new(:run_completed, %{completed: %{ok: true}}, %{session_key: session_key})

      async_fn = fn fun ->
        # Execute synchronously for testing
        fun.()
        :ok
      end

      result = ReactionTracker.handle_run_completed(state, event, async_fn)
      refute Map.has_key?(result.reaction_runs, session_key)
    end

    test "returns state unchanged when session_key not tracked" do
      state =
        base_state()
        |> Map.put(:reaction_runs, %{})

      event = Event.new(:run_completed, %{ok: true}, %{session_key: "unknown"})

      result = ReactionTracker.handle_run_completed(state, event, fn _fun -> :ok end)
      assert result.reaction_runs == %{}
    end

    test "returns state unchanged when event has no session_key" do
      state =
        base_state()
        |> Map.put(:reaction_runs, %{"some_key" => %{chat_id: 1}})

      event = Event.new(:run_completed, %{ok: true}, %{})

      result = ReactionTracker.handle_run_completed(state, event, fn _fun -> :ok end)
      assert Map.has_key?(result.reaction_runs, "some_key")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_state(opts \\ []) do
    api_mod = Keyword.get(opts, :api_mod, SuccessAPI)

    %{
      token: "test_token",
      api_mod: api_mod,
      account_id: "test",
      reaction_runs: %{}
    }
  end
end
