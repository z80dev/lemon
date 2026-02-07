defmodule Ai.Integration.OpenAICodexOAuthLiveTest do
  use ExUnit.Case, async: false

  @live System.get_env("LEMON_CODEX_LIVE_TEST") == "1"

  @moduletag :integration
  @moduletag skip:
               if(@live,
                 do: false,
                 else:
                   "Set LEMON_CODEX_LIVE_TEST=1 to run (requires local `codex login` credentials)."
               )
  @moduletag timeout: 180_000

  alias Ai.Auth.OpenAICodexOAuth
  alias Ai.EventStream
  alias Ai.Models
  alias Ai.Providers.OpenAICodexResponses

  alias Ai.Types.{AssistantMessage, Context, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)
    :ok
  end

  test "can resolve Codex OAuth token from local Codex CLI login" do
    token = OpenAICodexOAuth.resolve_access_token()
    assert is_binary(token)
    assert token != ""
    # JWT-like shape (header.payload.sig) to avoid printing/handling token content.
    assert length(String.split(token, ".")) == 3
  end

  test "can make a minimal Codex Responses request using local Codex OAuth token" do
    token = OpenAICodexOAuth.resolve_access_token()
    assert is_binary(token)
    assert token != ""

    model =
      Models.get_model(:"openai-codex", "gpt-5.2") ||
        Models.get_model(:"openai-codex", "gpt-5.2-codex")

    assert model != nil

    context =
      Context.new(
        system_prompt: "You are a concise assistant.",
        messages: [
          %UserMessage{
            content: "Reply with exactly: ok",
            timestamp: System.system_time(:millisecond)
          }
        ]
      )

    {:ok, stream} =
      OpenAICodexResponses.stream(
        model,
        context,
        %StreamOptions{
          api_key: token,
          stream_timeout: 150_000
        }
      )

    case EventStream.result(stream, 150_000) do
      {:ok, %AssistantMessage{stop_reason: stop_reason} = msg} ->
        assert stop_reason != :error

        text =
          msg.content
          |> Enum.filter(&match?(%{type: :text}, &1))
          |> Enum.map(&Map.get(&1, :text))
          |> Enum.join("")

        assert is_binary(text)
        assert String.trim(text) != ""

      {:error, %AssistantMessage{} = msg} ->
        flunk("Codex call failed: #{msg.error_message}")

      other ->
        flunk("Unexpected result: #{inspect(other)}")
    end
  end
end
