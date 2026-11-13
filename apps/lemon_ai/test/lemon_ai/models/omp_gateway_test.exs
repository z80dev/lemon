defmodule LemonAi.Models.OmpGatewayTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, Models}
  alias LemonAi.Models.OmpGateway
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

  @base_url "http://gateway.test:4000/v1"

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "discovery routes each chat model to its native wire and skips other kinds" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:listing, conn.request_path, conn.req_headers})

      Req.Test.json(conn, %{
        "object" => "list",
        "data" => [
          %{
            "id" => "anthropic/claude-haiku-4-5",
            "api" => "anthropic-messages",
            "display_name" => "Claude Haiku 4.5",
            "context_length" => 200_000,
            "max_output_tokens" => 64_000,
            "input_modalities" => ["text", "image"]
          },
          %{"id" => "openai-codex/gpt-6-luna", "api" => "openai-codex-responses"},
          %{"id" => "openrouter/vendor/model:free", "api" => "openrouter"},
          %{
            "id" => "openai/text-embedding-3-small",
            "api" => "openai-embeddings",
            "kind" => "embedding"
          },
          %{"id" => "typesafe/jev-latest", "api" => "openrouter-decisions", "kind" => "judge"}
        ]
      })
    end)

    assert {:ok, models} =
             Models.discover_preset(:omp_gateway,
               base_url: @base_url,
               api_key: "gateway-bearer",
               headers: %{"x-team" => "lemon"},
               force_refresh: true
             )

    assert_receive {:listing, "/v1/models", headers}
    assert {"authorization", "Bearer gateway-bearer"} in headers

    by_id = Map.new(models, &{&1.id, &1})

    assert Map.keys(by_id) |> Enum.sort() ==
             [
               "anthropic/claude-haiku-4-5",
               "openai-codex/gpt-6-luna",
               "openrouter/vendor/model:free"
             ]

    claude = by_id["anthropic/claude-haiku-4-5"]
    assert claude.provider == :omp_gateway
    assert claude.api == :anthropic_messages
    # The Anthropic wire module appends /v1/messages itself.
    assert claude.base_url == "http://gateway.test:4000"
    assert claude.input == [:text, :image]
    assert claude.max_tokens == 64_000
    # Reasoning metadata and pricing come from Lemon's catalog entry.
    catalog = Models.get_model(:anthropic, "claude-haiku-4-5")
    assert claude.reasoning == catalog.reasoning
    assert claude.cost == catalog.cost
    assert claude.headers["x-omp-app"] == "lemon"
    assert claude.headers["x-team"] == "lemon"

    assert by_id["openai-codex/gpt-6-luna"].api == :openai_responses
    assert by_id["openai-codex/gpt-6-luna"].base_url == @base_url
    assert by_id["openrouter/vendor/model:free"].api == :openai_completions
  end

  test "ids outside any discovery listing still pick a wire from the catalog" do
    claude = OmpGateway.model("anthropic/claude-haiku-4-5", nil, @base_url)
    assert claude.api == :anthropic_messages
    assert claude.base_url == "http://gateway.test:4000"

    codex = OmpGateway.model("openai-codex/gpt-6-luna", nil, @base_url)
    assert codex.api == :openai_responses

    unknown = OmpGateway.model("somewhere/whatever", nil, @base_url)
    assert unknown.api == :openai_completions
    assert unknown.base_url == @base_url
    assert unknown.reasoning == false
  end

  test "Anthropic Messages requests authenticate to the gateway with a bearer" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:request, conn.request_path, conn.req_headers})

      body =
        Enum.map_join(
          [
            {"message_start",
             %{
               "type" => "message_start",
               "message" => %{
                 "id" => "msg_1",
                 "usage" => %{"input_tokens" => 3, "output_tokens" => 0}
               }
             }},
            {"content_block_start",
             %{
               "type" => "content_block_start",
               "index" => 0,
               "content_block" => %{"type" => "text", "text" => ""}
             }},
            {"content_block_delta",
             %{
               "type" => "content_block_delta",
               "index" => 0,
               "delta" => %{"type" => "text_delta", "text" => "pong"}
             }},
            {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
            {"message_delta",
             %{
               "type" => "message_delta",
               "delta" => %{"stop_reason" => "end_turn"},
               "usage" => %{"output_tokens" => 1}
             }},
            {"message_stop", %{"type" => "message_stop"}}
          ],
          fn {event, data} -> "event: #{event}\ndata: #{Jason.encode!(data)}\n\n" end
        )

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    model = OmpGateway.model("anthropic/claude-haiku-4-5", nil, @base_url)
    context = Context.new(messages: [%UserMessage{content: "ping"}])

    {:ok, stream} =
      LemonAi.Providers.Anthropic.stream(model, context, %StreamOptions{api_key: "gateway-bearer"})

    assert {:ok, result} = EventStream.result(stream, 5_000)
    assert result.stop_reason == :stop

    assert_receive {:request, "/v1/messages", headers}
    assert {"authorization", "Bearer gateway-bearer"} in headers
    refute List.keymember?(headers, "x-api-key", 0)
    assert {"x-omp-app", "lemon"} in headers
  end
end
