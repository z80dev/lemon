defmodule CodingAgent.Tools.BashStreamingPreviewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.StreamingPreview
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  test "small replacement snapshots retain the original accumulated output" do
    state = StreamingPreview.new(16)
    assert StreamingPreview.render(state) == ""

    state = state |> StreamingPreview.append("hello ") |> StreamingPreview.append("world")

    assert StreamingPreview.render(state) == "hello world"
    refute state.truncated
  end

  test "exactly filling the budget does not mark the preview truncated" do
    state = StreamingPreview.new(4) |> StreamingPreview.append("1234")

    assert StreamingPreview.render(state) == "1234"
    refute state.truncated
  end

  test "many chunks remain bounded and preserve the most recent output" do
    final =
      Enum.reduce(1..1000, StreamingPreview.new(32), fn index, state ->
        next = StreamingPreview.append(state, "chunk-#{index}\n")
        assert byte_size(next.text) <= 32
        assert String.valid?(next.text)
        next
      end)

    assert final.truncated
    assert String.ends_with?(StreamingPreview.render(final), "chunk-1000\n")
    assert StreamingPreview.render(final) =~ "Earlier output omitted"
  end

  test "a large source binary is not retained by the bounded tail" do
    state = StreamingPreview.new(64) |> StreamingPreview.append(String.duplicate("x", 1_000_000))

    assert state.text == String.duplicate("x", 64)
    assert :binary.referenced_byte_size(state.text) == byte_size(state.text)
  end

  test "truncation never leaves a UTF-8 continuation byte at the start" do
    for budget <- 1..12 do
      state =
        StreamingPreview.new(budget)
        |> StreamingPreview.append("start 🦁🍋 café")
        |> StreamingPreview.append(" 🍋!")

      assert byte_size(state.text) <= budget
      assert String.valid?(state.text)
      assert String.valid?(StreamingPreview.render(state))
      assert String.ends_with?(state.text, "!")
    end
  end

  test "invalid byte limits are rejected" do
    for budget <- [0, -1, nil, :infinity] do
      assert_raise ArgumentError, fn -> StreamingPreview.new(budget) end
    end
  end

  test "the real bash callback emits bounded untrusted replacement snapshots" do
    caller = self()
    marker = make_ref()

    result =
      Bash.execute(
        "bounded-preview",
        %{"command" => "printf '%60000s' ''; printf 'END'"},
        nil,
        fn update -> send(caller, {marker, update}) end,
        System.tmp_dir!(),
        []
      )

    if result.details[:full_output_path] do
      on_exit(fn -> File.rm(result.details.full_output_path) end)
    end

    assert result.details.exit_code == 0
    updates = collect_updates(marker, [])
    assert updates != []

    for %AgentToolResult{content: [%TextContent{text: text}], trust: trust} <- updates do
      assert trust == :untrusted
      assert byte_size(text) <= 50_000 + 100
    end

    assert %AgentToolResult{content: [%TextContent{text: last}]} = List.last(updates)
    assert String.ends_with?(last, "END")
    assert last =~ "Earlier output omitted"
  end

  defp collect_updates(marker, acc) do
    receive do
      {^marker, update} -> collect_updates(marker, [update | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
