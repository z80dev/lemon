defmodule LemonChannels.VoiceReplyTest do
  use ExUnit.Case, async: true

  alias LemonChannels.VoiceReply

  defmodule FakeProvider do
    @behaviour LemonChannels.VoiceProvider
    def synthesize(text, config, context) do
      send(context.owner, {:synthesized, text, config})

      Map.get(
        context,
        :result,
        {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}}
      )
    end
  end

  defmodule FakeHTTP do
    def request(:post, {url, headers, content_type, body}, opts, response_opts) do
      send(
        self(),
        {:http_request, url, headers, content_type, Jason.decode!(body), opts, response_opts}
      )

      id = make_ref()

      case Process.get(:speech_response, {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "opus"}}) do
        {:ok, {{_, 200, _}, headers, audio}} ->
          chunks = Process.get(:speech_chunks, [audio])
          Process.put(:speech_pending, {id, chunks})
          send(self(), {:http, {id, :stream_start, headers, self()}})

        {:ok, response} ->
          send(self(), {:http, {id, response}})
      end

      {:ok, id}
    end

    def stream_next(_stream) do
      send(self(), :stream_demand)
      {id, chunks} = Process.get(:speech_pending)

      case chunks do
        [chunk | rest] ->
          Process.put(:speech_pending, {id, rest})
          send(self(), {:http, {id, :stream, chunk}})

        [] ->
          send(self(), {:http, {id, :stream_end, []}})
      end

      :ok
    end

    def cancel_request(id) do
      send(self(), {:http_cancelled, id})
      :ok
    end
  end

  defp config,
    do: %{provider: "openai", model: "gpt-4o-mini-tts", voice: "alloy", api_key: "test-key"}

  defp context do
    owner = self()

    %{
      owner: owner,
      provider_module: FakeProvider,
      run_id: "voice-test-run",
      session_key: "voice-test-session",
      delivery_id: "delivery-1",
      usage_recorder: fn entry ->
        send(owner, {:usage, entry})
        :ok
      end
    }
  end

  defp http_context do
    context()
    |> Map.delete(:provider_module)
    |> Map.merge(%{
      http_client: FakeHTTP,
      http_stream_next: &FakeHTTP.stream_next/1,
      http_cancel: &FakeHTTP.cancel_request/1
    })
  end

  test "fake synthesis preserves audio and unknown response cost" do
    assert {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}} =
             VoiceReply.synthesize("Hello", config(), context())

    assert_receive {:synthesized, "Hello", _}
    assert_receive {:usage, entry}
    assert entry.run_id == "voice-test-run"
    assert entry.occurrence == "voice_reply:delivery-1"
    assert entry.cost == nil
    refute entry.price_known
    record = LemonCore.UsageLedger.occurrence_record(entry)
    assert record.cost_usd == nil
    assert record.input_characters == 5
    refute record.price_known
  end

  test "actual provider usage is recorded without an estimated price" do
    audio = %{
      audio_bytes: "opus",
      mime_type: "audio/ogg",
      filename: "reply.ogg",
      usage: %{input_tokens: 3, output_tokens: 7, cost_usd: 0.012}
    }

    assert {:ok, result} =
             VoiceReply.synthesize(
               "Hello",
               Map.put(config(), :price_per_million_characters, 20),
               Map.put(context(), :result, {:ok, audio})
             )

    refute Map.has_key?(result, :usage)
    assert_receive {:usage, %{input: 3, output: 7, cost: 0.012, price_known: true}}
  end

  test "provider failures and malformed audio record no successful usage" do
    assert {:error, :offline} =
             VoiceReply.synthesize(
               "Hello",
               config(),
               Map.put(context(), :result, {:error, :offline})
             )

    assert {:error, :invalid_audio} =
             VoiceReply.synthesize("Hello", config(), Map.put(context(), :result, {:ok, %{}}))

    refute_receive {:usage, _}
  end

  test "unconfigured provider and empty text never invoke synthesis" do
    assert {:error, :unsupported_provider} = VoiceReply.synthesize("Hello", %{}, context())
    assert {:error, :empty_text} = VoiceReply.synthesize(" ", config(), context())
    refute_receive {:synthesized, _, _}
  end

  test "usage recorder failure does not discard already synthesized audio" do
    assert {:ok, %{audio_bytes: "opus"}} =
             VoiceReply.synthesize(
               "Hello",
               config(),
               Map.put(context(), :usage_recorder, fn _ -> exit(:unavailable) end)
             )
  end

  test "production provider posts OpenAI speech JSON through the HTTP seam" do
    ctx = http_context()
    assert {:ok, %{audio_bytes: "opus"}} = VoiceReply.synthesize("Hello", config(), ctx)

    assert_receive {:http_request, ~c"https://api.openai.com/v1/audio/speech", headers,
                    ~c"application/json", body, _, response_opts}

    assert response_opts == [body_format: :binary, sync: false, stream: {:self, :once}]

    assert {~c"authorization", ~c"Bearer test-key"} in headers

    assert body == %{
             "input" => "Hello",
             "model" => "gpt-4o-mini-tts",
             "voice" => "alloy",
             "response_format" => "opus"
           }

    assert_receive {:usage, %{cost: nil, price_known: false, input_characters: 5}}
  end

  test "production provider without usage uses configured model character pricing" do
    # Test tariff, not a claim about the production model's published price.
    config = Map.put(config(), :price_per_million_characters, 20)
    text = "Hello 世界"
    assert {:ok, %{audio_bytes: "opus"}} = VoiceReply.synthesize(text, config, http_context())
    assert_receive {:usage, entry}
    assert entry.input_characters == 8
    assert_in_delta entry.cost, 0.00016, 0.000000001
    assert entry.price_known
    assert entry.input == 0
    assert entry.output == 0
    record = LemonCore.UsageLedger.occurrence_record(entry)
    assert record.input_characters == 8
    assert record.cost_usd == entry.cost
  end

  test "production provider preserves explicit zero character pricing" do
    config = Map.put(config(), :price_per_million_characters, 0)
    assert {:ok, _} = VoiceReply.synthesize("Hello", config, http_context())
    assert_receive {:usage, %{cost: cost, price_known: true, input_characters: 5}}
    assert cost == 0.0
  end

  test "HTTP error details and credentials are not exposed" do
    Process.put(
      :speech_response,
      {:ok, {{~c"HTTP/1.1", 401, ~c"Unauthorized"}, [], "private response"}}
    )

    ctx = http_context()
    assert {:error, {:http_error, 401}} = VoiceReply.synthesize("Hello", config(), ctx)
    refute_receive {:usage, _}
  end

  test "missing credentials and empty API audio fail closed" do
    ctx = http_context()

    assert {:error, :missing_api_key} =
             VoiceReply.synthesize("Hello", Map.delete(config(), :api_key), ctx)

    Process.put(:speech_response, {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ""}})
    assert {:error, :empty_audio} = VoiceReply.synthesize("Hello", config(), ctx)
    refute_receive {:usage, _}
  end

  test "oversized fake provider audio is rejected before usage or delivery output" do
    audio = %{
      audio_bytes: :binary.copy(<<0>>, VoiceReply.max_audio_bytes() + 1),
      mime_type: "audio/ogg",
      filename: "reply.ogg"
    }

    assert {:error, :audio_too_large} =
             VoiceReply.synthesize("Hello", config(), Map.put(context(), :result, {:ok, audio}))

    refute_receive {:usage, _}
  end

  test "HTTP audio is cancelled at the byte limit without demanding the remaining response" do
    Process.put(:speech_chunks, [
      :binary.copy(<<0>>, VoiceReply.max_audio_bytes()),
      "x",
      "never requested"
    ])

    assert {:error, :audio_too_large} =
             VoiceReply.synthesize("Hello", config(), http_context())

    assert_receive {:http_cancelled, _}
    assert_receive :stream_demand
    assert_receive :stream_demand
    refute_receive :stream_demand
    assert {_id, ["never requested"]} = Process.get(:speech_pending)
    refute_receive {:usage, _}
  end

  test "HTTP audio at the exact byte limit succeeds across chunks" do
    first = :binary.copy(<<0>>, VoiceReply.max_audio_bytes() - 1)
    Process.put(:speech_chunks, [first, "x"])

    assert {:ok, %{audio_bytes: audio}} =
             VoiceReply.synthesize("Hello", config(), http_context())

    assert byte_size(audio) == VoiceReply.max_audio_bytes()
    assert_receive {:usage, _}
    refute_receive {:http_cancelled, _}
  end
end
