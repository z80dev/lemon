defmodule LemonAi.Providers.OpenAICompletionsCacheWireTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, Providers.OpenAICompletions}
  alias LemonAi.Types.{Context, Model, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous_defaults = Req.default_options()
    Req.default_options(Keyword.delete(previous_defaults, :plug))

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :http_bin,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()

    start_supervised!(
      Supervisor.child_spec({Task, fn -> serve_requests(listener, owner) end},
        restart: :temporary
      )
    )

    on_exit(fn ->
      :gen_tcp.close(listener)
      Req.default_options(previous_defaults)
    end)

    %{base_url: "http://127.0.0.1:#{port}/v1"}
  end

  for provider <- [
        :openai,
        "openai",
        :openrouter,
        "openrouter",
        :mistral,
        "mistral",
        :together,
        "together",
        :vercel_ai_gateway,
        "vercel_ai_gateway",
        :xai,
        "xai",
        :fireworks,
        "fireworks"
      ] do
    test "#{inspect(provider)} sends stable session affinity on the HTTP wire", %{
      base_url: base_url
    } do
      provider = unquote(provider)
      first = request(base_url, provider, "session-a", "First turn")
      second = request(base_url, provider, "session-a", "Next turn")
      resumed = request(base_url, provider, "session-a", "Resumed turn")
      distinct = request(base_url, provider, "session-b", "First turn")

      assert cache_identity(first, provider) == "session-a"
      assert cache_identity(second, provider) == cache_identity(first, provider)
      assert cache_identity(resumed, provider) == cache_identity(first, provider)
      assert cache_identity(distinct, provider) == "session-b"
      refute cache_identity(distinct, provider) == cache_identity(first, provider)

      for wire <- [first, second, resumed, distinct] do
        assert_only_provider_control(wire, provider)
      end

      for missing <- [nil, ""] do
        wire = request(base_url, provider, missing, "Without session")
        assert_no_cache_controls(wire)
      end
    end
  end

  test "long sessions are bounded and remain distinct after a common prefix", %{
    base_url: base_url
  } do
    prefix = String.duplicate("session-", 50)

    for provider <- [
          :openai,
          :openrouter,
          :mistral,
          :together,
          :vercel_ai_gateway,
          :xai,
          :fireworks
        ] do
      first = request(base_url, provider, prefix <> "a", "First")
      repeated = request(base_url, provider, prefix <> "a", "Next")
      distinct = request(base_url, provider, prefix <> "b", "First")
      id = cache_identity(first, provider)

      assert is_binary(id)
      assert byte_size(id) <= 64
      assert cache_identity(repeated, provider) == id
      refute cache_identity(distinct, provider) == id
    end
  end

  test "does not leak provider-specific controls to incompatible endpoints", %{base_url: base_url} do
    for provider <- [
          :groq,
          :zai,
          :deepseek,
          :cerebras,
          :minimax,
          :moonshot,
          :opencode,
          "custom-openai-compatible"
        ] do
      wire = request(base_url, provider, "session-a", "First turn")
      assert_no_cache_controls(wire)
    end
  end

  test "explicit affinity headers retain normal case-insensitive override precedence", %{
    base_url: base_url
  } do
    for {provider, header} <- [{:xai, "x-grok-conv-id"}, {:fireworks, "x-session-affinity"}] do
      wire =
        request(base_url, provider, "generated-session", "First turn",
          model_headers: %{String.upcase(header) => "model-session"},
          headers: %{header => "explicit-session"}
        )

      assert cache_identity(wire, provider) == "explicit-session"
      assert Enum.count(wire.headers, fn {name, _} -> name == header end) == 1
    end
  end

  defp request(base_url, provider, session_id, text, options \\ []) do
    model = %Model{
      id: "cache-wire-model",
      provider: provider,
      api: :openai_completions,
      base_url: base_url,
      headers: Keyword.get(options, :model_headers, %{})
    }

    context = Context.new(messages: [%UserMessage{content: text}])

    {:ok, stream} =
      OpenAICompletions.stream(model, context, %StreamOptions{
        api_key: "synthetic-wire-key",
        session_id: session_id,
        headers: Keyword.get(options, :headers, %{})
      })

    assert_receive {:wire_request, wire}, 5_000
    assert wire.path == "/v1/chat/completions"
    assert {:ok, result} = EventStream.result(stream, 5_000)
    assert LemonAi.get_text(result) == "ok"
    wire
  end

  defp cache_identity(wire, provider)
       when provider in [:openai, "openai", :mistral, "mistral", :together, "together"],
       do: wire.body["prompt_cache_key"]

  defp cache_identity(wire, provider)
       when provider in [:openrouter, "openrouter", :vercel_ai_gateway, "vercel_ai_gateway"],
       do: wire.body["session_id"]

  defp cache_identity(wire, provider) when provider in [:xai, "xai"],
    do: Map.new(wire.headers)["x-grok-conv-id"]

  defp cache_identity(wire, provider) when provider in [:fireworks, "fireworks"],
    do: Map.new(wire.headers)["x-session-affinity"]

  defp assert_only_provider_control(wire, provider) do
    assert Map.has_key?(wire.body, "prompt_cache_key") ==
             provider in [:openai, "openai", :mistral, "mistral", :together, "together"]

    assert Map.has_key?(wire.body, "session_id") ==
             provider in [:openrouter, "openrouter", :vercel_ai_gateway, "vercel_ai_gateway"]

    headers = Map.new(wire.headers)
    assert Map.has_key?(headers, "x-grok-conv-id") == provider in [:xai, "xai"]
    assert Map.has_key?(headers, "x-session-affinity") == provider in [:fireworks, "fireworks"]
    refute Map.has_key?(headers, "x-session-id")
  end

  defp assert_no_cache_controls(wire) do
    refute Map.has_key?(wire.body, "prompt_cache_key")
    refute Map.has_key?(wire.body, "session_id")
    headers = Map.new(wire.headers)

    for header <- ["x-grok-conv-id", "x-session-affinity", "x-session-id"] do
      refute Map.has_key?(headers, header)
    end
  end

  defp serve_requests(listener, owner) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        try do
          assert {:ok, {:http_request, :POST, {:abs_path, path}, _}} =
                   :gen_tcp.recv(socket, 0, 5_000)

          headers = read_headers(socket, [])
          length = headers |> Map.new() |> Map.fetch!("content-length") |> String.to_integer()
          :ok = :inet.setopts(socket, packet: :raw)
          assert {:ok, raw} = :gen_tcp.recv(socket, length, 5_000)
          send(owner, {:wire_request, %{path: path, headers: headers, body: Jason.decode!(raw)}})

          body =
            "data: " <>
              Jason.encode!(%{
                "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]
              }) <> "\n\ndata: [DONE]\n\n"

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\n",
              "content-type: text/event-stream\r\n",
              "content-length: #{byte_size(body)}\r\n",
              "connection: close\r\n\r\n",
              body
            ])
        after
          :gen_tcp.close(socket)
        end

        serve_requests(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        Enum.reverse(headers)

      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, [{name |> to_string() |> String.downcase(), value} | headers])
    end
  end
end
