defmodule LemonEvals.SupportTest do
  use ExUnit.Case, async: true

  alias LemonEvals.Support

  describe "assert_contains/2" do
    test "passes when the expected substring is present" do
      assert Support.assert_contains("hello world", "world") == :ok
    end

    test "fails with a descriptive reason when the substring is missing" do
      assert {:error, reason} = Support.assert_contains("hello world", "missing")
      assert reason =~ "missing"
      assert reason =~ "hello world"
    end
  end

  describe "format_reason/1" do
    test "returns binaries unchanged" do
      assert Support.format_reason("already a string") == "already a string"
    end

    test "inspects non-binary reasons" do
      assert Support.format_reason({:error, :boom}) == inspect({:error, :boom})
    end
  end

  describe "stringify_content/1" do
    test "passes binaries through" do
      assert Support.stringify_content("plain text") == "plain text"
    end

    test "joins lists of content blocks" do
      assert Support.stringify_content([%{text: "first"}, %{text: "second"}]) ==
               "first\nsecond"
    end

    test "extracts text from map-shaped content" do
      assert Support.stringify_content(%{text: "block text"}) == "block text"
      assert Support.stringify_content(%{"text" => "string-keyed"}) == "string-keyed"
    end

    test "falls back to empty string for unrecognized shapes" do
      assert Support.stringify_content(%{other: "field"}) == ""
    end
  end

  describe "message_role/1 and message_content/1" do
    test "reads atom-keyed role and content" do
      message = %{role: :assistant, content: "hi"}
      assert Support.message_role(message) == :assistant
      assert Support.message_content(message) == "hi"
    end

    test "reads string-keyed role" do
      assert Support.message_role(%{"role" => "tool_result"}) == :tool_result
      assert Support.message_role(%{"role" => "user"}) == :user
    end

    test "returns nil/empty for unrecognized message shapes" do
      assert Support.message_role(%{}) == nil
      assert Support.message_content(nil) == ""
    end
  end

  describe "tool_calls/1" do
    test "reads atom-keyed and string-keyed tool_calls" do
      assert Support.tool_calls(%{tool_calls: [%{id: "1"}]}) == [%{id: "1"}]
      assert Support.tool_calls(%{"tool_calls" => [%{"id" => "2"}]}) == [%{"id" => "2"}]
    end

    test "returns an empty list when absent" do
      assert Support.tool_calls(%{}) == []
    end
  end

  describe "completed_action_claim?/1 and unbacked_tool_claim?/1" do
    test "detects a claim of a completed side-effecting action" do
      assert Support.completed_action_claim?("I created deployment-notes.md.")
    end

    test "does not flag ordinary text without a side-effect claim" do
      refute Support.completed_action_claim?("Sure, I can help with that.")
    end

    test "flags an assistant claim with no preceding tool activity" do
      messages = [
        %{role: :user, content: "Create a deployment notes file."},
        %{role: :assistant, content: "Done, I created deployment-notes.md."}
      ]

      assert Support.unbacked_tool_claim?(messages)
    end

    test "does not flag a claim backed by an actual tool call and result" do
      messages = [
        %{role: :user, content: "Create a deployment notes file."},
        %{role: :assistant, content: "", tool_calls: [%{id: "call_write", name: "write"}]},
        %{role: :tool_result, tool_call_id: "call_write", tool_name: "write", content: "ok"},
        %{role: :assistant, content: "Done, I created deployment-notes.md."}
      ]

      refute Support.unbacked_tool_claim?(messages)
    end
  end

  describe "contract_fail/3" do
    test "builds a failing eval result merging reason into details" do
      result = Support.contract_fail("some_contract", "went wrong", %{extra: 1})

      assert result == %{
               name: "some_contract",
               status: :fail,
               details: %{reason: "went wrong", extra: 1}
             }
    end
  end

  describe "create_tmp_dir/0 and write_fixture_file/1" do
    test "creates a usable temp directory with a readable fixture file" do
      assert {:ok, tmp_dir} = Support.create_tmp_dir()
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      assert File.dir?(tmp_dir)
      assert {:ok, path} = Support.write_fixture_file(tmp_dir)
      assert File.read!(path) == "alpha\nbeta\n"
    end
  end
end
