defmodule LemonControlPlane.Methods.SessionsRoutingMetaTest do
  @moduledoc """
  The read side of a session's routing: what model it will run on, and where that came from.

  `sessions.list` answers cheaply (the override only) and `session.detail` answers fully
  (resolved model, provider, window); these tests pin that split so a later change cannot
  quietly make the listing do per-row model resolution.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{SessionDetail, SessionsList}

  defp fresh_key, do: "session_routing_#{System.unique_integer([:positive])}"

  describe "sessions.list" do
    test "every row carries a model key" do
      {:ok, result} = SessionsList.handle(%{}, %{})

      for row <- result["sessions"] do
        assert Map.has_key?(row, "model"),
               "sessions.list row is missing the model key: #{inspect(row)}"
      end
    end

    test "a row shows the session's override once one is pinned" do
      key = fresh_key()
      now = System.system_time(:millisecond)

      LemonCore.Store.put(:sessions_index, key, %{
        session_key: key,
        agent_id: "default",
        origin: :control_plane,
        created_at_ms: now,
        updated_at_ms: now,
        run_count: 1
      })

      LemonCore.PolicyStore.put_session(key, %{model: "gpt-5.4"})

      {:ok, result} = SessionsList.handle(%{"limit" => 500}, %{})
      row = Enum.find(result["sessions"], &(&1["sessionKey"] == key))

      assert row, "seeded session did not appear in sessions.list"
      assert row["model"] == "gpt-5.4"

      LemonCore.PolicyStore.delete_session(key)
      LemonCore.RunStore.delete_session_index(key)
    end
  end

  describe "session.detail" do
    test "resolves the model, its provider and its context window" do
      key = fresh_key()
      LemonCore.PolicyStore.put_session(key, %{model: "claude-sonnet-4-20250514"})

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})
      session = result["session"]

      assert session["model"] == "claude-sonnet-4-20250514"
      assert session["provider"] == "anthropic"
      assert session["modelSource"] == "session"
      assert session["modelOverride"] == "claude-sonnet-4-20250514"
      assert is_integer(session["contextWindow"]) and session["contextWindow"] > 0

      LemonCore.PolicyStore.delete_session(key)
    end

    test "reports thinking level with fixed native provenance" do
      key = fresh_key()

      LemonCore.PolicyStore.put_session(key, %{
        model: "gpt-5.4",
        thinking_level: "high"
      })

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})

      assert result["session"]["thinkingLevel"] == "high"
      assert result["session"]["engine"] == "lemon"
      refute Map.has_key?(result["session"], "preferredEngine")

      LemonCore.PolicyStore.delete_session(key)
    end

    test "an unpinned session reports a null override, not a null session" do
      key = fresh_key()

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})
      session = result["session"]

      assert session["sessionKey"] == key
      assert session["modelOverride"] == nil
      refute session["modelSource"] == "session"
    end

    test "still requires a session key" do
      assert {:error, error} = SessionDetail.handle(%{}, %{})
      assert inspect(error) =~ "sessionKey"
    end
  end
end
