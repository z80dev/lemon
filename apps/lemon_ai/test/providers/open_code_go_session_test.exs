defmodule LemonAi.Providers.OpenCodeGoSessionTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.{Anthropic, OpenAICompletions, OpenCodeGoSession}
  alias LemonAi.Types.{Context, Model, StreamOptions, UserMessage}

  @header "x-opencode-session"

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp openai_model(provider) do
    %Model{
      id: "deepseek-v4-flash",
      name: "DeepSeek V4 Flash",
      api: :openai_completions,
      provider: provider,
      base_url: "https://opencode.ai/zen/go/v1"
    }
  end

  defp anthropic_model(provider) do
    %Model{
      id: "minimax-m2.5",
      name: "MiniMax M2.5",
      api: :anthropic_messages,
      provider: provider,
      base_url: "https://opencode.ai/zen/go",
      max_tokens: 2048
    }
  end

  defp context(system_prompt \\ "You are a werewolf.") do
    Context.new(system_prompt: system_prompt, messages: [%UserMessage{content: "Hi"}])
  end

  defp openai_done_body, do: "data: [DONE]\n"

  defp anthropic_done_body do
    "event: message_stop\ndata: " <> Jason.encode!(%{"type" => "message_stop"}) <> "\n\n"
  end

  # Runs one request through `provider_module` and returns the request headers.
  defp request_headers(provider_module, model, context, opts, body) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    {:ok, stream} = provider_module.stream(model, context, opts)
    assert_receive {:request_headers, headers}, 1000
    assert {:ok, _result} = EventStream.result(stream, 1000)
    Map.new(headers)
  end

  describe "OpenCodeGoSession.headers/3" do
    test "fallback id is stable per system prompt and never empty" do
      model = openai_model(:opencode_go)
      opts = %StreamOptions{}

      assert %{@header => id} = OpenCodeGoSession.headers(model, context("prompt A"), opts)
      assert id != ""
      assert %{@header => ^id} = OpenCodeGoSession.headers(model, context("prompt A"), opts)
      assert %{@header => other} = OpenCodeGoSession.headers(model, context("prompt B"), opts)
      assert other != id

      assert %{@header => nil_prompt_id} =
               OpenCodeGoSession.headers(model, Context.new(messages: []), opts)

      assert nil_prompt_id != ""
    end
  end

  describe "openai_completions provider" do
    test "sends x-opencode-session from opts.session_id for opencode_go" do
      headers =
        request_headers(
          OpenAICompletions,
          openai_model(:opencode_go),
          context(),
          %StreamOptions{api_key: "k", session_id: "game-1:player-2"},
          openai_done_body()
        )

      assert headers[@header] == "game-1:player-2"
    end

    test "sends a fallback x-opencode-session for opencode_go without session_id" do
      headers =
        request_headers(
          OpenAICompletions,
          openai_model(:opencode_go),
          context(),
          %StreamOptions{api_key: "k"},
          openai_done_body()
        )

      assert is_binary(headers[@header]) and headers[@header] != ""
    end

    test "opts.headers can override the session header" do
      headers =
        request_headers(
          OpenAICompletions,
          openai_model(:opencode_go),
          context(),
          %StreamOptions{api_key: "k", session_id: "a", headers: %{"X-OpenCode-Session" => "b"}},
          openai_done_body()
        )

      assert headers[@header] == "b"
    end

    test "does not send x-opencode-session for other providers" do
      headers =
        request_headers(
          OpenAICompletions,
          openai_model(:opencode),
          context(),
          %StreamOptions{api_key: "k", session_id: "game-1:player-2"},
          openai_done_body()
        )

      refute Map.has_key?(headers, @header)
    end
  end

  describe "anthropic provider" do
    test "sends x-opencode-session from opts.session_id for opencode_go" do
      headers =
        request_headers(
          Anthropic,
          anthropic_model(:opencode_go),
          context(),
          %StreamOptions{api_key: "k", session_id: "game-1:player-2"},
          anthropic_done_body()
        )

      assert headers[@header] == "game-1:player-2"
    end

    test "does not send x-opencode-session for other providers" do
      headers =
        request_headers(
          Anthropic,
          anthropic_model(:opencode),
          context(),
          %StreamOptions{api_key: "k", session_id: "game-1:player-2"},
          anthropic_done_body()
        )

      refute Map.has_key?(headers, @header)
    end
  end
end
