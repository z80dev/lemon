defmodule LemonAi.Providers.TransportErrorTest do
  use ExUnit.Case, async: false

  alias LemonAi.{Error, EventStream}

  alias LemonAi.Providers.{
    AssistantMessageHelper,
    OpenAICodexResponses,
    OpenAIResponses,
    OpenAIResponsesShared,
    SSEParser
  }

  alias LemonAi.Types.{AssistantMessage, Context, Model, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    defaults = Req.default_options()
    retry = Application.get_env(:lemon_ai, :provider_retry)
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:lemon_ai, :provider_retry, max_attempts: 1)

    on_exit(fn ->
      Req.default_options(defaults)
      Req.Test.set_req_test_to_private(%{})

      if retry,
        do: Application.put_env(:lemon_ai, :provider_retry, retry),
        else: Application.delete_env(:lemon_ai, :provider_retry)
    end)

    :ok
  end

  test "status-zero network failures and generic throttling are not account exhaustion" do
    assert %{category: :transient, retryable: true} =
             Error.parse_http_error(0, "other side closed connection")

    assert %{category: :rate_limit, retryable: true} =
             Error.parse_http_error(400, "RESOURCE_EXHAUSTED: quota exceeded")

    depleted = %{
      "error" => %{
        "status" => "RESOURCE_EXHAUSTED",
        "message" => "Quota exceeded",
        "details" => [%{"reason" => "INSUFFICIENT_G1_CREDITS_BALANCE"}]
      }
    }

    assert %{category: :rate_limit, retryable: false} =
             Error.parse_http_error(400, depleted)
  end

  test "Finch and Mint closed/reset/timeout failures classify from typed reasons" do
    for reason <- [:closed, :econnreset, :timeout],
        exception <- [
          %Req.TransportError{reason: reason},
          %Mint.TransportError{reason: reason},
          %Finch.TransportError{reason: reason, source: %Mint.TransportError{reason: reason}}
        ] do
      assert Error.classify(exception) == :transient
      assert Error.retryable?(exception)
      details = Error.to_error_details(exception)
      assert %{category: :transient, retryable: true, status: nil} = details
      refute Map.has_key?(details, :source)
      assert is_binary(Jason.encode!(details))
    end

    observed =
      "Connection failed: %Finch.TransportError{reason: :closed, source: %Mint.TransportError{reason: :closed}}"

    assert Error.classify(observed) == :transient
    assert Error.retryable?(observed)
  end

  test "pre-response transport failures reach both Responses providers with structured metadata" do
    failure = %Finch.TransportError{
      reason: :closed,
      source: %Mint.TransportError{reason: :closed}
    }

    Req.Test.stub(__MODULE__, fn conn -> put_in(conn.private[:req_test_exception], failure) end)

    jwt =
      "header." <>
        Base.url_encode64(
          Jason.encode!(%{
            "https://api.openai.com/auth" => %{"chatgpt_account_id" => "synthetic"}
          }),
          padding: false
        ) <> ".signature"

    context = Context.new(messages: [%UserMessage{content: "Hello"}])

    for {provider, api, id, key} <- [
          {OpenAICodexResponses, :openai_codex_responses, :openai_codex, jwt},
          {OpenAIResponses, :openai_responses, :openai, "synthetic-key"}
        ] do
      model = %Model{
        id: "synthetic-model",
        api: api,
        provider: id,
        base_url: "https://example.invalid/v1"
      }

      {:ok, stream} = provider.stream(model, context, %StreamOptions{api_key: key})
      assert {:error, %AssistantMessage{} = message} = EventStream.result(stream, 1_000)
      assert %{category: :transient, retryable: true} = message.error_details
      assert Error.retryable?(%{message | error_message: "Opaque display-only failure"})
      refute message.error_message =~ "Finch.TransportError"
    end
  end

  test "mid-stream transport failure survives SSE parsing and assistant terminal delivery" do
    ref = make_ref()

    failure = %Finch.TransportError{
      reason: :closed,
      source: %Mint.TransportError{reason: :closed}
    }

    response = %Req.Response{
      body: %Req.Response.Async{
        ref: ref,
        stream_fun: fn ^ref, {^ref, :failed} -> {:error, failure} end,
        cancel_fun: fn ^ref -> :ok end
      }
    }

    send(self(), {ref, :failed})
    {:ok, stream} = EventStream.start_link()

    assert {:error, ^failure} =
             OpenAIResponsesShared.process_stream(
               SSEParser.events(response, 100),
               %AssistantMessage{},
               stream,
               %Model{}
             )

    message = AssistantMessageHelper.error_assistant_message(%AssistantMessage{}, failure)
    EventStream.error(stream, message)
    assert {:error, terminal} = EventStream.result(stream, 1_000)
    assert %{category: :transient, retryable: true} = terminal.error_details
    assert Error.classify(terminal) == :transient
    assert Error.retryable?(terminal)
  end

  test "terminal metadata retains server hints and cannot make permanent failures retryable" do
    details = Error.parse_http_error(503, "Service Unavailable", [{"retry-after", "1.5"}])
    message = AssistantMessageHelper.error_assistant_message(%AssistantMessage{}, details)
    assert message.error_details.rate_limit_info.retry_after == 1_500
    assert Error.retryable?(message)
    permanent = Error.to_error_details(%{category: :auth, message: "opaque", retryable: true})
    refute permanent.retryable

    refute Error.retryable?(%AssistantMessage{
             error_message: "connection closed",
             error_details: permanent
           })
  end
end
