defmodule CodingAgent.Tools.BashStreamingPreviewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.StreamingPreview
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  test "small replacement snapshots retain the original accumulated output" do
    state = StreamingPreview.new()
    assert StreamingPreview.render(state) == ""

    state = state |> StreamingPreview.append("hello ") |> StreamingPreview.append("world")

    assert StreamingPreview.render(state) == "hello world"
    refute state.truncated
  end

  test "exactly filling the budget does not mark the preview truncated" do
    text = String.duplicate("x", 50_000)
    state = StreamingPreview.new() |> StreamingPreview.append(text)

    assert StreamingPreview.render(state) == text
    refute state.truncated
  end

  test "many chunks remain bounded and preserve the most recent output" do
    final =
      Enum.reduce(1..10_000, StreamingPreview.new(), fn index, state ->
        next = StreamingPreview.append(state, "chunk-#{index}\n")
        assert byte_size(next.text) <= 50_000
        assert String.valid?(next.text)
        next
      end)

    assert final.truncated
    assert String.ends_with?(StreamingPreview.render(final), "chunk-10000\n")
    assert StreamingPreview.render(final) =~ "Earlier output omitted"
  end

  test "a large source binary is not retained by the bounded tail" do
    state = StreamingPreview.new() |> StreamingPreview.append(String.duplicate("x", 1_000_000))

    assert state.text == String.duplicate("x", 50_000)
    assert :binary.referenced_byte_size(state.text) == byte_size(state.text)
  end

  test "truncation never leaves a UTF-8 continuation byte at the start" do
    for prefix_bytes <- 0..11 do
      state =
        StreamingPreview.new()
        |> StreamingPreview.append("🦁🍋 café" <> String.duplicate("x", 49_988 + prefix_bytes))
        |> StreamingPreview.append(" 🍋!")

      assert byte_size(state.text) <= 50_000
      assert String.valid?(state.text)
      assert String.valid?(StreamingPreview.render(state))
      assert String.ends_with?(state.text, "!")
    end
  end

  test "the real bash callback emits bounded untrusted replacement snapshots" do
    # The executor drains its mailbox while collecting shell output.
    # Keep observations in a separate supervised process.
    updates_pid = start_supervised!({Agent, fn -> [] end})

    result =
      Bash.execute(
        "bounded-preview",
        %{"command" => "printf '%60000s' ''; sleep 0.1; printf 'END'"},
        nil,
        fn update -> Agent.update(updates_pid, &[update | &1]) end,
        System.tmp_dir!(),
        []
      )

    if result.details[:full_output_path] do
      on_exit(fn -> File.rm(result.details.full_output_path) end)
    end

    assert result.details.exit_code == 0
    updates = Agent.get(updates_pid, &Enum.reverse/1)
    assert updates != []

    for update <- updates do
      assert %AgentToolResult{content: [%TextContent{text: text}], trust: :untrusted} = update
      assert byte_size(text) <= 50_000 + 100
    end

    assert %AgentToolResult{content: [%TextContent{text: last}]} = List.last(updates)
    assert String.ends_with?(last, "END")
    assert last =~ "Earlier output omitted"
  end
end
