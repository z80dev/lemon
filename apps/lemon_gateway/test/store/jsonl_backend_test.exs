defmodule LemonGateway.Store.JsonlBackendTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Store.JsonlBackend

  setup do
    # Create a unique temp directory for each test
    tmp_dir =
      Path.join(System.tmp_dir!(), "jsonl_backend_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "init/1" do
    test "creates the storage directory", %{tmp_dir: tmp_dir} do
      refute File.exists?(tmp_dir)

      {:ok, _state} = JsonlBackend.init(path: tmp_dir)

      assert File.dir?(tmp_dir)
    end

    test "returns error when directory creation fails" do
      # Try to create directory in non-existent parent with no permissions
      bad_path = "/nonexistent_root_#{System.unique_integer()}/store"

      assert {:error, {:mkdir_failed, ^bad_path, _reason}} = JsonlBackend.init(path: bad_path)
    end

    test "works with existing directory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(tmp_dir)

      {:ok, _state} = JsonlBackend.init(path: tmp_dir)
    end
  end

  describe "put/4 and get/3" do
    test "stores and retrieves values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "key1", %{"foo" => "bar"})
      {:ok, value, _state} = JsonlBackend.get(state, :chat, "key1")

      assert value == %{"foo" => "bar"}
    end

    test "returns nil for missing keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, value, _state} = JsonlBackend.get(state, :chat, "missing")
      assert value == nil
    end

    test "overwrites existing values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "first")
      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "second")
      {:ok, value, _state} = JsonlBackend.get(state, :chat, "key1")

      assert value == "second"
    end

    test "stores in different tables independently", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "chat_value")
      {:ok, state} = JsonlBackend.put(state, :runs, "key1", "runs_value")

      {:ok, chat_value, state} = JsonlBackend.get(state, :chat, "key1")
      {:ok, runs_value, _state} = JsonlBackend.get(state, :runs, "key1")

      assert chat_value == "chat_value"
      assert runs_value == "runs_value"
    end

    test "handles tuple keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      key = {:scope, 123}
      {:ok, state} = JsonlBackend.put(state, :progress, key, "run_id")
      {:ok, value, _state} = JsonlBackend.get(state, :progress, key)

      assert value == "run_id"
    end

    test "handles atom keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, :my_key, "value")
      {:ok, value, _state} = JsonlBackend.get(state, :chat, :my_key)

      assert value == "value"
    end

    test "writes to JSONL file", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, _state} = JsonlBackend.put(state, :chat, "key1", %{"data" => 123})

      file_path = Path.join(tmp_dir, "chat.jsonl")
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert String.contains?(content, "\"op\":\"put\"")
      assert String.contains?(content, "\"key\":\"key1\"")
    end
  end

  describe "delete/3" do
    test "removes a key", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "value")
      {:ok, state} = JsonlBackend.delete(state, :chat, "key1")
      {:ok, value, _state} = JsonlBackend.get(state, :chat, "key1")

      assert value == nil
    end

    test "writes delete operation to file", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "value")
      {:ok, _state} = JsonlBackend.delete(state, :chat, "key1")

      file_path = Path.join(tmp_dir, "chat.jsonl")
      content = File.read!(file_path)
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 2
      assert String.contains?(Enum.at(lines, 1), "\"op\":\"delete\"")
    end
  end

  describe "list/2" do
    test "returns all key-value pairs", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, state} = JsonlBackend.put(state, :chat, "a", 1)
      {:ok, state} = JsonlBackend.put(state, :chat, "b", 2)
      {:ok, state} = JsonlBackend.put(state, :chat, "c", 3)

      {:ok, items, _state} = JsonlBackend.list(state, :chat)

      assert length(items) == 3
      assert {"a", 1} in items
      assert {"b", 2} in items
      assert {"c", 3} in items
    end

    test "returns empty list for empty table", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      {:ok, items, _state} = JsonlBackend.list(state, :chat)
      assert items == []
    end
  end

  describe "persistence" do
    test "data survives reload", %{tmp_dir: tmp_dir} do
      # Write data
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      {:ok, state} = JsonlBackend.put(state, :chat, "key1", %{"foo" => "bar"})
      {:ok, state} = JsonlBackend.put(state, :runs, "run1", %{"events" => [1, 2, 3]})
      {:ok, _state} = JsonlBackend.put(state, :progress, {:scope, 123}, "run1")

      # Reload from scratch
      {:ok, new_state} = JsonlBackend.init(path: tmp_dir)

      # Verify data is preserved
      {:ok, chat_value, new_state} = JsonlBackend.get(new_state, :chat, "key1")
      {:ok, runs_value, new_state} = JsonlBackend.get(new_state, :runs, "run1")
      {:ok, progress_value, _state} = JsonlBackend.get(new_state, :progress, {:scope, 123})

      assert chat_value == %{"foo" => "bar"}
      assert runs_value == %{"events" => [1, 2, 3]}
      assert progress_value == "run1"
    end

    test "delete operations are replayed correctly", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "value1")
      {:ok, state} = JsonlBackend.put(state, :chat, "key2", "value2")
      {:ok, _state} = JsonlBackend.delete(state, :chat, "key1")

      # Reload
      {:ok, new_state} = JsonlBackend.init(path: tmp_dir)

      {:ok, value1, new_state} = JsonlBackend.get(new_state, :chat, "key1")
      {:ok, value2, _state} = JsonlBackend.get(new_state, :chat, "key2")

      assert value1 == nil
      assert value2 == "value2"
    end

    test "updates are replayed correctly", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      {:ok, state} = JsonlBackend.put(state, :chat, "key1", "first")
      {:ok, _state} = JsonlBackend.put(state, :chat, "key1", "second")

      # Reload
      {:ok, new_state} = JsonlBackend.init(path: tmp_dir)

      {:ok, value, _state} = JsonlBackend.get(new_state, :chat, "key1")
      assert value == "second"
    end

    test "handles complex nested structures", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      complex_value = %{
        "events" => [
          %{"type" => "started", "ts" => 1_234_567_890},
          %{"type" => "completed", "ts" => 1_234_567_900}
        ],
        "summary" => %{
          "ok" => true,
          "answer" => "test response"
        }
      }

      {:ok, _state} = JsonlBackend.put(state, :runs, "run123", complex_value)

      # Reload
      {:ok, new_state} = JsonlBackend.init(path: tmp_dir)
      {:ok, value, _state} = JsonlBackend.get(new_state, :runs, "run123")

      assert value == complex_value
    end
  end
end
