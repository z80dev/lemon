defmodule LemonAi.Providers.RetrySafetyTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.{Anthropic, OpenAICompletions}
  alias LemonAi.Types.{Context, Model, ModelCost, StreamOptions, UserMessage}

  setup do
    defaults = Req.default_options()
    retry = Application.get_env(:lemon_ai, :provider_retry)
    parent = self()
    Application.put_env(:lemon_ai, :provider_retry,
      max_attempts: 2,
      base_delay_ms: 2,
      sleep_fun: fn ms -> send(parent, {:provider_sleep, ms}); :ok end
    )

    on_exit(fn ->
      Req.default_options(defaults)
      if retry do
        Application.put_env(:lemon_ai, :provider_retry, retry)
      else
        Application.delete_env(:lemon_ai, :provider_retry)
      end
    end)

    :ok
  end

  defp model(api, provider) do
    %Model{
      id: "retry-test", name: "Retry Test", api: api, provider: provider,
      base_url: "https://retry.example.test", input: [:text],
      cost: %ModelCost{}, max_tokens: 1024
    }
  end

  defp context, do: Context.new(messages: [%UserMessage{content: "Hi"}])
  defp options, do: %StreamOptions{api_key: "fake-test-key"}

  defp anthropic_event(kind, value) do
    "event: #{kind}\ndata: #{Jason.encode!(value)}\n\n"
  end

  defp anthropic_metadata do
    anthropic_event("message_start", %{"message" => %{"usage" => %{}}})
  end

  defp anthropic_success do
    anthropic_metadata() <>
      anthropic_event("content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}) <>
      anthropic_event("content_block_delta", %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "ok"}}) <>
      anthropic_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
      anthropic_event("message_stop", %{})
  end

  defp anthropic_adapter(body, outcome) do
    parent = self()
    fn request ->
      send(parent, :provider_request)
      response = %Req.Response{status: 200}
      {:cont, {request, response}} = request.into.({:data, body}, {request, response})
      case outcome do
        :error -> {request, %Req.TransportError{reason: :closed}}
        :success -> {request, response}
      end
    end
  end

  test "Anthropic never retries transport failures after output starts or whitespace" do
    for {block, delta, expected_event} <- [
          {%{"type" => "text"}, nil, :text_start},
          {%{"type" => "text"}, %{"type" => "text_delta", "text" => " "}, :text_delta},
          {%{"type" => "thinking"}, nil, :thinking_start},
          {%{"type" => "thinking"}, %{"type" => "thinking_delta", "thinking" => " "}, :thinking_delta},
          {%{"type" => "tool_use", "id" => "call_1", "name" => "echo", "input" => %{}}, nil, :tool_call_start}
        ] do
      body = anthropic_metadata() <>
        anthropic_event("content_block_start", %{"index" => 0, "content_block" => block}) <>
        if(delta, do: anthropic_event("content_block_delta", %{"index" => 0, "delta" => delta}), else: "")

      Req.default_options(adapter: anthropic_adapter(body, :error))
      assert {:ok, stream} = Anthropic.stream(model(:anthropic_messages, :anthropic), context(), options())
      events = Enum.to_list(EventStream.events(stream))
      assert Enum.any?(events, &(elem(&1, 0) == expected_event))
      assert {:error, terminal} = EventStream.result(stream, 1_000)
      assert terminal.stop_reason == :error
      # The transport terminal uses the initial empty output; the emitted event,
      # rather than terminal content length, must keep this attempt committed.
      assert terminal.content == []
      assert_receive :provider_request
      refute_received :provider_request
      refute_received {:provider_sleep, _}
    end
  end

  test "Anthropic metadata-only transport failure remains retryable" do
    parent = self()
    {:ok, count} = Agent.start_link(fn -> 0 end)
    first = anthropic_adapter(anthropic_metadata(), :error)
    second = anthropic_adapter(anthropic_success(), :success)
    Req.default_options(adapter: fn request ->
      attempt = Agent.get_and_update(count, fn n -> {n, n + 1} end)
      send(parent, {:attempt, attempt})
      if attempt == 0, do: first.(request), else: second.(request)
    end)

    assert {:ok, stream} = Anthropic.stream(model(:anthropic_messages, :anthropic), context(), options())
    assert {:ok, message} = EventStream.result(stream, 1_000)
    assert LemonAi.get_text(message) == "ok"
    assert_receive {:attempt, 0}
    assert_receive {:attempt, 1}
    assert_receive {:provider_sleep, _}
    assert_receive :provider_request
    assert_receive :provider_request
    refute_received :provider_request
  end

  defp openai_body(delta) do
    "data: #{Jason.encode!(%{"choices" => [%{"delta" => delta}]})}\n\n"
  end

  defp openai_adapter(body, outcome) do
    parent = self()
    fn request ->
      send(parent, :provider_request)
      ref = make_ref()
      pid = self()
      send(pid, {ref, {:data, body}})
      case outcome do
        :error -> send(pid, {:DOWN, ref, :process, pid, :closed})
        :success -> send(pid, {ref, :done})
      end
      {request, %Req.Response{status: 200, body: %Req.Response.Async{pid: pid, ref: ref}}}
    end
  end

  test "OpenAI completions never retries text, thinking or tool transport failures" do
    for {delta, expected_event} <- [
          {%{"content" => " "}, :text_delta},
          {%{"reasoning_content" => " "}, :thinking_delta},
          {%{"tool_calls" => [%{"index" => 0, "id" => "call_1", "function" => %{"name" => "echo", "arguments" => ""}}]}, :tool_call_start}
        ] do
      Req.default_options(adapter: openai_adapter(openai_body(delta), :error))
      assert {:ok, stream} = OpenAICompletions.stream(model(:openai_completions, :openai), context(), options())
      events = Enum.to_list(EventStream.events(stream))
      assert Enum.any?(events, &(elem(&1, 0) == expected_event))
      assert {:error, %{stop_reason: :error}} = EventStream.result(stream, 1_000)
      assert_receive :provider_request
      refute_received :provider_request
      refute_received {:provider_sleep, _}
    end
  end

  test "OpenAI completions metadata-only transport failure remains retryable" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    first = openai_adapter(openai_body(%{}), :error)
    second = openai_adapter(openai_body(%{"content" => "ok"}), :success)
    Req.default_options(adapter: fn request ->
      attempt = Agent.get_and_update(count, fn n -> {n, n + 1} end)
      if attempt == 0, do: first.(request), else: second.(request)
    end)

    assert {:ok, stream} = OpenAICompletions.stream(model(:openai_completions, :openai), context(), options())
    assert {:ok, message} = EventStream.result(stream, 1_000)
    assert LemonAi.get_text(message) == "ok"
    assert_receive :provider_request
    assert_receive :provider_request
    refute_received :provider_request
    assert_receive {:provider_sleep, _}
  end
end
