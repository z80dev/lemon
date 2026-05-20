defmodule LemonControlPlane.Methods.EventSubscriptionMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{
    EventsSubscribe,
    EventsSubscriptionsList,
    EventsUnsubscribe
  }

  test "subscribe returns normalized topics and sends connection update" do
    {:ok, result} =
      EventsSubscribe.handle(
        %{"topics" => ["system", "session:abc"], "runId" => "run-1"},
        %{conn_id: "conn-1", conn_pid: self()}
      )

    assert result["subscribed"] == true
    assert "system" in result["topics"]
    assert "session:abc" in result["topics"]
    assert "run:run-1" in result["topics"]
    assert result["summary"]["topicCount"] == 3
    assert result["summary"]["runSubscriptionCount"] == 1
    assert result["summary"]["sessionSubscriptionCount"] == 1
    assert result["summary"]["cleanup"]["includesPayloads"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
    assert_receive {:subscribe_topics, ["system", "session:abc", "run:run-1"]}
  end

  test "subscriptions.list uses connection state from context" do
    {:ok, result} =
      EventsSubscriptionsList.handle(%{}, %{
        conn_id: "conn-1",
        subscriptions: MapSet.new(["run:run-1", "system", "session:abc"])
      })

    assert result["subscriptions"] == ["run:run-1", "session:abc", "system"]
    assert result["runSubscriptions"] == ["run-1"]
    assert result["count"] == 3
    assert result["summary"]["topicCount"] == 3
    assert result["summary"]["runSubscriptionCount"] == 1
    assert result["summary"]["sessionSubscriptionCount"] == 1
    assert result["summary"]["cleanup"]["includesPayloads"] == false
    assert result["summary"]["cleanup"]["includesMessageBodies"] == false
  end

  test "subscriptions.list reports default all-subscription mode" do
    {:ok, result} =
      EventsSubscriptionsList.handle(%{}, %{
        conn_id: "conn-1",
        subscription_mode: :all,
        subscriptions: MapSet.new()
      })

    assert result["subscriptions"] == ["all"]
    assert result["count"] == 1
    assert result["summary"]["topicCount"] == 1
  end

  test "unsubscribe supports specific topics and all-topic clear" do
    {:ok, result} =
      EventsUnsubscribe.handle(%{"topics" => ["system"], "runId" => "run-1"}, %{
        conn_id: "conn-1",
        conn_pid: self()
      })

    assert result["unsubscribed"] == true
    assert result["topics"] == ["system", "run:run-1"]
    assert result["summary"]["topicCount"] == 2
    assert result["summary"]["all"] == false
    assert_receive {:unsubscribe_topics, ["system", "run:run-1"]}

    {:ok, clear} = EventsUnsubscribe.handle(%{}, %{conn_id: "conn-1", conn_pid: self()})

    assert clear["topics"] == nil
    assert clear["summary"]["all"] == true
    assert_receive {:unsubscribe_topics, :all}
  end

  test "subscribe rejects invalid topic values" do
    {:error, {:invalid_request, message}} =
      EventsSubscribe.handle(%{"topics" => ["system", "bad topic"]}, %{})

    assert message =~ "Invalid topics"
    assert message =~ "bad topic"
  end
end
