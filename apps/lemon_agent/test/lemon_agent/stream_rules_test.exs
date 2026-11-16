defmodule LemonAgent.StreamRulesTest do
  use ExUnit.Case, async: true

  alias LemonAgent.StreamRules
  alias LemonAgent.StreamRules.Error
  alias LemonAgent.Types.AgentContext
  alias LemonAi.Types.{AssistantMessage, TextContent}

  test "matches text split across deltas and returns the rule without injecting it" do
    rule = rule("forbidden")
    state = StreamRules.new([rule])

    assert {state, nil} = StreamRules.feed(state, {:text_delta, 0, "for"})
    assert {_state, ^rule} = StreamRules.feed(state, {:text_delta, 0, "bidden"})
  end

  test "matches raw tool argument fragments without decoding JSON" do
    rule = rule(~S(rm\s+-rf))
    state = StreamRules.new([rule])

    assert {state, nil} =
             StreamRules.feed(state, {:tool_call_delta, 0, ~s({"command":"rm )})

    assert {_state, ^rule} =
             StreamRules.feed(state, {:tool_call_delta, 0, ~s(-rf /tmp/work"})})
  end

  test "isolates text blocks and individual tool argument streams" do
    rule = rule("forbidden")
    state = StreamRules.new([rule])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, "for"})
    {state, nil} = StreamRules.feed(state, {:text_delta, 1, "bidden"})
    {state, nil} = StreamRules.feed(state, {:tool_call_delta, 0, "bidden"})
    {state, nil} = StreamRules.feed(state, {:tool_call_delta, 1, "for"})
    {state, nil} = StreamRules.feed(state, {:tool_call_delta, 2, "bidden"})

    assert {_state, ^rule} =
             StreamRules.feed(state, {:tool_call_delta, 1, "bidden"})
  end

  test "interleaved argument fragments keep the correct call's prefix" do
    rule = rule("forbidden")
    state = StreamRules.new([rule])
    {state, nil} = StreamRules.feed(state, {:tool_call_delta, 4, "for"})
    {state, nil} = StreamRules.feed(state, {:tool_call_delta, 9, "unrelated"})

    assert {_state, ^rule} = StreamRules.feed(state, {:tool_call_delta, 4, "bidden"})
  end

  test "block starts and ends prevent matches across reused content indices" do
    for {kind, start_event, end_kind} <- [
          {:text_delta, {:text_start, 0}, :text_end},
          {:tool_call_delta, {:tool_call_start, 0, %LemonAi.Types.ToolCall{}}, :tool_call_end}
        ] do
      state = StreamRules.new([rule("forbidden")])
      {state, nil} = StreamRules.feed(state, {kind, 0, "for"})
      {state, nil} = StreamRules.feed(state, {end_kind, 0, nil})
      assert state.buffers == %{}
      {state, nil} = StreamRules.feed(state, {kind, 0, "bidden"})
      {state, nil} = StreamRules.feed(state, start_event)
      assert state.buffers == %{{kind, 0} => ""}
      assert {_state, nil} = StreamRules.feed(state, {kind, 0, "bidden"})
    end
  end

  test "response lifecycle events release all retained output" do
    state = StreamRules.new([rule("forbidden")])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, "for"})

    for event <- [{:start, nil}, {:done, :stop, nil}, {:error, :error, nil}, {:canceled, :abort}] do
      assert {cleared, nil} = StreamRules.feed(state, event)
      assert cleared.buffers == %{}
      assert {_state, nil} = StreamRules.feed(cleared, {:text_delta, 0, "bidden"})
    end
  end

  test "does not inspect snapshots, thinking, or context and never adds dormant rules" do
    rule = rule("forbidden")
    partial = %AssistantMessage{content: [%TextContent{text: "forbidden"}]}
    context = %AgentContext{system_prompt: "original", messages: [partial]}
    state = StreamRules.new([rule])

    assert {^state, nil} = StreamRules.feed(state, {:start, partial})
    assert {^state, nil} = StreamRules.feed(state, {:thinking_delta, 0, "forbidden"})
    assert {next, nil} = StreamRules.feed(state, {:text_delta, 0, "safe"})
    assert next.buffers == %{{:text_delta, 0} => "safe"}
    assert next.rules == state.rules
    assert context == %AgentContext{system_prompt: "original", messages: [partial]}
    refute Map.has_key?(next, :context)
  end

  test "empty rules are a no-op even for an oversized delta" do
    state = StreamRules.new([])
    event = {:text_delta, 0, :binary.copy("x", 1_000_000)}
    assert {^state, nil} = StreamRules.feed(state, event)
  end

  test "first rule in declaration order wins within a window" do
    first = rule("forbidden", %{name: "first"})
    second = rule("bidden", %{name: "second"})
    state = StreamRules.new([first, second])

    assert {_state, ^first} = StreamRules.feed(state, {:text_delta, 0, "forbidden"})
  end

  test "does not own injection limits or suppress later matches" do
    rule = rule("forbidden", %{injection_limit: 1})
    state = StreamRules.new([rule])
    {state, ^rule} = StreamRules.feed(state, {:text_delta, 0, "forbidden"})
    assert {_state, ^rule} = StreamRules.feed(state, {:text_delta, 1, "forbidden"})
  end

  test "scans the beginning, middle, and end of maximum-sized accepted deltas" do
    rule = rule("forbidden")

    for offset <- [0, 1020, 4093, 8190, 16_384 - byte_size("forbidden")] do
      delta =
        :binary.copy("x", offset) <>
          "forbidden" <> :binary.copy("x", 16_384 - offset - byte_size("forbidden"))

      assert {_state, ^rule} =
               StreamRules.feed(StreamRules.new([rule]), {:text_delta, 0, delta})
    end
  end

  test "keeps a prefix across the delta boundary when the next delta fills the window" do
    rule = rule("forbidden")
    state = StreamRules.new([rule])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, "for"})
    delta = "bidden" <> :binary.copy("x", 16_378)

    assert {_state, ^rule} = StreamRules.feed(state, {:text_delta, 0, delta})
  end

  test "retains only the last 4096 bytes and bounds the number of stream buffers" do
    state = StreamRules.new([rule("forbidden")])
    delta = :binary.copy("x", 16_384)

    state =
      Enum.reduce(0..31, state, fn index, state ->
        {state, nil} = StreamRules.feed(state, {:tool_call_delta, index, delta})
        state
      end)

    assert map_size(state.buffers) == 32

    for {_key, buffer} <- state.buffers do
      assert byte_size(buffer) == 4096
      assert :binary.referenced_byte_size(buffer) == 4096
    end

    assert_error(:too_many_streams, fn ->
      StreamRules.feed(state, {:text_delta, 32, "x"})
    end)

    {state, nil} = StreamRules.feed(state, {:tool_call_end, 0, nil})
    assert {_state, nil} = StreamRules.feed(state, {:text_delta, 32, "x"})
  end

  test "expired output cannot participate in future matches" do
    state = StreamRules.new([rule("for.*bidden")])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, "for"})
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, :binary.copy("x", 8192)})

    assert {_state, nil} = StreamRules.feed(state, {:text_delta, 0, "bidden"})
  end

  test "retained binaries do not pin an oversized input's backing binary" do
    backing = :binary.copy("x", 1_000_000)
    delta = binary_part(backing, 10, 512)
    assert :binary.referenced_byte_size(delta) > byte_size(delta)
    state = StreamRules.new([rule("forbidden")])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, delta})

    assert :binary.referenced_byte_size(state.buffers[{:text_delta, 0}]) == 512
  end

  test "rejects oversized input before matching even a violation at its beginning" do
    state = StreamRules.new([rule("forbidden")])

    for kind <- [:text_delta, :tool_call_delta], bytes <- [16_385, 1_000_000] do
      delta = "forbidden" <> :binary.copy("x", bytes - byte_size("forbidden"))

      assert_error(:delta_too_large, fn ->
        StreamRules.feed(state, {kind, 0, delta})
      end)
    end

    assert state.buffers == %{}
  end

  test "pathological regexes fail explicitly at the engine budget" do
    source = ~S"(*NO_START_OPT)(*NO_AUTO_POSSESS)\A(a+)+\z"
    state = StreamRules.new([rule(source)])
    delta = :binary.copy("a", 32) <> "!"

    error = assert_raise Error, fn -> StreamRules.feed(state, {:text_delta, 0, delta}) end
    assert error.reason in [:match_limit, :match_limit_recursion]
    refute Exception.message(error) =~ source
    assert state.buffers == %{}
  end

  test "deep recursion fails explicitly rather than becoming a missed match" do
    source = ~S"\A(\((?1)?\))\z"
    state = StreamRules.new([rule(source)])
    delta = :binary.copy("(", 200) <> :binary.copy(")", 200)

    assert_error(:match_limit_recursion, fn ->
      StreamRules.feed(state, {:text_delta, 0, delta})
    end)
  end

  test "byte windows handle split UTF-8 without enabling Unicode regex mode" do
    rule = rule("é")
    state = StreamRules.new([rule])
    {state, nil} = StreamRules.feed(state, {:text_delta, 0, <<0xC3>>})
    assert {_state, ^rule} = StreamRules.feed(state, {:text_delta, 0, <<0xA9>>})

    assert_error(:invalid_pattern, fn -> StreamRules.new([rule("(*UTF)é")]) end)
  end

  test "accepts exact configuration byte limits and any positive injection limit" do
    rules =
      for index <- 1..32 do
        rule(:binary.copy("x", 1024), %{
          name: String.pad_leading(Integer.to_string(index), 256, "x"),
          content: :binary.copy("x", 65_536),
          injection_limit: Integer.pow(2, 100)
        })
      end

    assert %StreamRules{} = StreamRules.new(rules)
  end

  test "validates finite rule configuration budgets before matching" do
    assert_error(:too_many_rules, fn -> StreamRules.new(List.duplicate(rule("x"), 33)) end)
    assert_error(:pattern_too_large, fn -> StreamRules.new([rule(:binary.copy("x", 1025))]) end)

    assert_error(:name_too_large, fn ->
      StreamRules.new([rule("x", %{name: :binary.copy("x", 257)})])
    end)

    assert_error(:content_too_large, fn ->
      StreamRules.new([rule("x", %{content: :binary.copy("x", 65_537)})])
    end)

    for limit <- [0, -1, nil, "1"] do
      assert_error(:invalid_rule, fn ->
        StreamRules.new([rule("x", %{injection_limit: limit})])
      end)
    end

    assert_error(:invalid_pattern, fn -> StreamRules.new([rule("[")]) end)
    assert_error(:invalid_rule, fn -> StreamRules.new([%{}]) end)
    assert_error(:invalid_rules, fn -> StreamRules.new(nil) end)
  end

  test "copies bounded rule fields and drops unrelated metadata" do
    backing = :binary.copy("x", 1_000_000)

    input =
      rule(binary_part(backing, 0, 128), %{
        name: binary_part(backing, 0, 256),
        content: binary_part(backing, 0, 4096),
        unrelated: backing
      })

    state = StreamRules.new([input])
    {_state, matched} = StreamRules.feed(state, {:text_delta, 0, :binary.copy("x", 128)})

    assert matched == Map.take(input, [:name, :content, :stream_pattern, :injection_limit])

    for field <- [:name, :content, :stream_pattern] do
      assert :binary.referenced_byte_size(matched[field]) == byte_size(matched[field])
    end
  end

  test "rejects invalid delta types and unbounded stream identifiers" do
    state = StreamRules.new([rule("x")])

    assert_error(:invalid_delta, fn -> StreamRules.feed(state, {:text_delta, 0, ["x"]}) end)

    for index <- [-1, 2_147_483_648, :binary.copy("x", 1_000_000)] do
      assert_error(:invalid_stream_index, fn ->
        StreamRules.feed(state, {:text_delta, index, "x"})
      end)
    end
  end

  defp rule(pattern, overrides \\ %{}) do
    Map.merge(
      %{
        name: "avoid-danger",
        content: "Use the safe alternative.",
        stream_pattern: pattern,
        injection_limit: 1
      },
      overrides
    )
  end

  defp assert_error(reason, fun) do
    error = assert_raise Error, fun
    assert error.reason == reason
  end
end
