defmodule CodingAgent.Session.MessageSerializationCustomMessageTest do
  use ExUnit.Case, async: false

  alias Ai.Types.{ImageContent, TextContent}
  alias CodingAgent.Messages.CustomMessage
  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  test "round-trips basic custom messages for async followups and other custom types" do
    for custom_type <- ["async_followup", "task_status"] do
      message = %CustomMessage{
        role: :custom,
        custom_type: custom_type,
        content: "Task finished",
        display: true,
        details: %{"task_id" => "task-123", "status" => "completed"},
        timestamp: 123
      }

      assert round_trip_custom_message(message) == message
    end
  end

  test "preserves details after JSON round-trip with string keys" do
    message = %CustomMessage{
      role: :custom,
      custom_type: "async_followup",
      content: "Child task finished",
      details: %{
        task_id: "task-123",
        result: %{status: "done", exit_code: 0}
      },
      timestamp: 456
    }

    restored = round_trip_custom_message(message)

    assert restored.details == %{
             "task_id" => "task-123",
             "result" => %{"status" => "done", "exit_code" => 0}
           }

    assert get_in(restored.details, ["task_id"]) == "task-123"
    assert get_in(restored.details, ["result", "status"]) == "done"
    assert restored.details[:task_id] == nil
  end

  test "round-trips string and content block shapes" do
    string_message = %CustomMessage{
      role: :custom,
      custom_type: "async_followup",
      content: "Plain text followup",
      details: %{},
      timestamp: 1
    }

    block_message = %CustomMessage{
      role: :custom,
      custom_type: "async_followup",
      content: [
        %TextContent{type: :text, text: "First block"},
        %ImageContent{type: :image, data: "ZmFrZQ==", mime_type: "image/png"}
      ],
      details: %{},
      timestamp: 2
    }

    assert round_trip_custom_message(string_message) == string_message

    assert round_trip_custom_message(block_message) == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: [
               %TextContent{type: :text, text: "First block"},
               %ImageContent{type: :image, data: "ZmFrZQ==", mime_type: "image/png"}
             ],
             display: true,
             details: %{},
             timestamp: 2
           }
  end

  test "handles empty details, nested details, nil fields, and display false" do
    assert round_trip_custom_message(%CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "No details",
             details: %{},
             timestamp: 10
           }) == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "No details",
             display: true,
             details: %{},
             timestamp: 10
           }

    assert round_trip_custom_message(%CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "Nested details",
             details: %{task: %{id: "task-1", meta: %{attempt: 2}}},
             timestamp: 11
           }) == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "Nested details",
             display: true,
             details: %{"task" => %{"id" => "task-1", "meta" => %{"attempt" => 2}}},
             timestamp: 11
           }

    assert round_trip_custom_message(%CustomMessage{
             role: :custom,
             custom_type: nil,
             content: nil,
             display: nil,
             details: nil,
             timestamp: nil
           }) == %CustomMessage{
             role: :custom,
             custom_type: "",
             content: "",
             display: true,
             details: nil,
             timestamp: 0
           }

    assert round_trip_custom_message(%CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "Hidden",
             display: false,
             details: %{},
             timestamp: 12
           }) == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "Hidden",
             display: false,
             details: %{},
             timestamp: 12
           }
  end

  @tag :tmp_dir
  test "SessionManager save_to_file/load_from_file round-trips custom_message entry details",
       %{
         tmp_dir: tmp_dir
       } do
    session =
      SessionManager.new(tmp_dir)
      |> SessionManager.append_entry(
        SessionEntry.custom_message("async_followup", "outer",
          display: false,
          details: %{
            task_id: "task-123",
            result: %{status: "done", exit_code: 0}
          }
        )
      )

    session_file = Path.join(tmp_dir, "custom_message_round_trip.jsonl")
    assert :ok = SessionManager.save_to_file(session_file, session)

    {:ok, loaded} = SessionManager.load_from_file(session_file)
    [entry] = SessionManager.entries(loaded)

    assert entry.type == :custom_message
    assert entry.custom_type == "async_followup"
    assert entry.content == "outer"
    assert entry.display == false

    assert entry.details == %{
             "task_id" => "task-123",
             "result" => %{"status" => "done", "exit_code" => 0}
           }
  end

  @tag :tmp_dir
  test "SessionManager persistence currently collapses CustomMessage structs in details via json_safe",
       %{
         tmp_dir: tmp_dir
       } do
    nested_message = %CustomMessage{
      role: :custom,
      custom_type: "nested",
      content: "inner",
      details: %{"status" => "done"},
      timestamp: 99
    }

    session =
      SessionManager.new(tmp_dir)
      |> SessionManager.append_entry(
        SessionEntry.custom_message("async_followup", "outer", details: nested_message)
      )

    session_file = Path.join(tmp_dir, "custom_message_json_safe_breakage.jsonl")
    assert :ok = SessionManager.save_to_file(session_file, session)

    {:ok, loaded} = SessionManager.load_from_file(session_file)
    [entry] = SessionManager.entries(loaded)

    assert entry.type == :custom_message
    assert is_binary(entry.details)
    assert String.contains?(entry.details, "CodingAgent.Messages.CustomMessage")
    assert String.contains?(entry.details, "custom_type: \"nested\"")
  end

  test "deserialize_message still reconstructs role=custom payloads" do
    payload = %{
      "role" => "custom",
      "custom_type" => "async_followup",
      "content" => "Task completed",
      "display" => false,
      "details" => %{"task_id" => "task-123", "status" => "done"},
      "timestamp" => 777
    }

    assert MessageSerialization.deserialize_message(payload) == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "Task completed",
             display: false,
             details: %{"task_id" => "task-123", "status" => "done"},
             timestamp: 777
           }
  end

  test "serialize_message currently falls through and returns the CustomMessage struct as-is" do
    message = %CustomMessage{
      role: :custom,
      custom_type: "async_followup",
      content: "Task completed",
      details: %{"task_id" => "task-123"},
      timestamp: 321
    }

    serialized = MessageSerialization.serialize_message(message)

    assert serialized == message
    assert match?(%CustomMessage{}, serialized)
    refute match?(%{"role" => "custom"}, serialized)
  end

  defp round_trip_custom_message(%CustomMessage{} = message) do
    message
    |> MessageSerialization.serialize_message()
    |> normalize_for_json()
    |> Jason.encode!()
    |> Jason.decode!()
    |> MessageSerialization.deserialize_message()
  end

  defp normalize_for_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_for_json()
  end

  defp normalize_for_json(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_for_json(value)} end)
  end

  defp normalize_for_json(list) when is_list(list), do: Enum.map(list, &normalize_for_json/1)
  defp normalize_for_json(true), do: true
  defp normalize_for_json(false), do: false
  defp normalize_for_json(nil), do: nil
  defp normalize_for_json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_for_json(other), do: other

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
