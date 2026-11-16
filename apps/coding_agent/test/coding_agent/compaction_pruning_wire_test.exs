defmodule CodingAgent.CompactionPruningWireTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Artifacts, Compaction, SessionManager}
  alias CodingAgent.Session.MessageSerialization
  alias LemonAi.Types.{Context, Model, StreamOptions, Tool}
  alias LemonAi.Providers

  @providers [
    {Providers.Anthropic, :anthropic_messages, :anthropic, "claude-sonnet-4-5", :anthropic},
    {Providers.OpenAIResponses, :openai_responses, :openai, "gpt-4o", :responses},
    {Providers.AzureOpenAIResponses, :azure_openai_responses, :azure_openai, "gpt-4o",
     :responses},
    {Providers.OpenAICodexResponses, :openai_codex_responses, :openai_codex, "gpt-5.2",
     :responses},
    {Providers.OpenAICompletions, :openai_completions, :openai, "gpt-4o", :chat},
    {Providers.MistralConversations, :mistral_conversations, :mistral, "mistral-large", :chat},
    {Providers.Google, :google_generative_ai, :google, "gpt-oss-120b", :google},
    {Providers.GoogleVertex, :google_vertex, :google_vertex, "gpt-oss-120b", :google},
    {Providers.GoogleGeminiCli, :google_gemini_cli, :google_gemini_cli, "gpt-oss-120b", :google},
    {Providers.Google, :google_generative_ai, :google, "gemini-3-pro", :google},
    {Providers.GoogleVertex, :google_vertex, :google_vertex, "gemini-3-pro", :google},
    {Providers.GoogleGeminiCli, :google_gemini_cli, :google_gemini_cli, "gemini-3-pro", :google},
    {Providers.Bedrock, :bedrock_converse_stream, :amazon,
     "anthropic.claude-3-5-haiku-20241022-v1:0", :bedrock}
  ]

  setup do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  for {provider_module, api, provider, model_id, wire} <- @providers do
    @tag :tmp_dir
    test "pruned parallel tool pairs survive #{api} #{model_id} request serialization", %{
      tmp_dir: cwd
    } do
      model = %Model{
        id: unquote(model_id),
        name: "Pruning fixture",
        api: unquote(api),
        provider: unquote(provider),
        base_url: "https://example.test",
        context_window: 200_000,
        max_tokens: 1024,
        input: [:text],
        headers: %{}
      }

      session = SessionManager.new(cwd)
      {:ok, directory} = Artifacts.spill_dir(cwd, session_id: session.header.id)
      on_exit(fn -> File.rm_rf!(directory) end)
      # Nine alphanumeric characters satisfy Mistral's wire ID contract too.
      ids = ["calloneAB", "calltwoAB"]

      call = %{
        "role" => "assistant",
        "provider" => model.provider,
        "api" => model.api,
        "model" => model.id,
        "stop_reason" => "tool_use",
        "content" =>
          Enum.map(ids, fn id ->
            # Gemini 3 only replays same-model calls with their thought signature.
            %{
              "type" => "tool_call",
              "id" => id,
              "name" => id,
              "arguments" => %{"q" => id},
              "thought_signature" =>
                if(String.starts_with?(model.id, "gemini-3"),
                  do: Base.encode64("fixture-signature")
                )
            }
          end)
      }

      results =
        Enum.map(ids, fn id ->
          %{
            "role" => "tool_result",
            "tool_call_id" => id,
            "tool_name" => id,
            "content" => [%{"type" => "text", "text" => String.duplicate(id, 1000)}]
          }
        end)

      recent = %{"role" => "user", "content" => String.duplicate("recent", 28_000)}

      session =
        Enum.reduce(
          [%{"role" => "user", "content" => "Look up both"}, call] ++ results ++ [recent],
          session,
          &SessionManager.append_message(&2, &1)
        )

      {projected, replacements} = Compaction.prune_tool_results(session)
      assert map_size(replacements) == 2

      messages =
        projected
        |> SessionManager.build_session_context()
        |> Map.fetch!(:messages)
        |> Enum.map(&MessageSerialization.deserialize_message/1)

      references =
        Enum.flat_map(messages, fn
          %LemonAi.Types.ToolResultMessage{content: [%LemonAi.Types.TextContent{text: text}]} ->
            [text]

          _ ->
            []
        end)

      assert length(references) == 2

      context =
        Context.new(
          messages: messages,
          tools:
            Enum.map(ids, fn id ->
              %Tool{
                name: id,
                description: "Lookup",
                parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
              }
            end)
        )

      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:pruning_wire_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      opts = options(unquote(api))
      assert {:ok, stream} = unquote(provider_module).stream(model, context, opts)
      assert_receive {:pruning_wire_body, body}, 5000
      assert {:error, _} = LemonAi.EventStream.result(stream, 5000)
      {calls, outputs} = wire_pairs(body, unquote(wire))
      assert Enum.sort(calls) == ids
      assert Enum.sort(Enum.map(outputs, &elem(&1, 0))) == ids

      for {id, output} <- outputs do
        assert id in calls
        [reference] = Enum.filter(references, &String.contains?(Jason.encode!(output), &1))
        assert String.contains?(reference, "artifact://")
      end
    end
  end

  defp options(api) do
    key =
      case api do
        :google_gemini_cli ->
          Jason.encode!(%{"token" => "fixture", "projectId" => "fixture"})

        :openai_codex_responses ->
          payload =
            Jason.encode!(%{
              "https://api.openai.com/auth" => %{"chatgpt_account_id" => "fixture"}
            })

          "header." <> Base.encode64(payload) <> ".signature"

        _ ->
          "fixture-key"
      end

    %StreamOptions{
      api_key: key,
      max_tokens: 1024,
      project: "fixture",
      location: "us-central1",
      access_token: "fixture",
      headers: %{
        "aws_access_key_id" => "AKIA_TEST",
        "aws_secret_access_key" => "SECRET",
        "aws_region" => "us-east-1"
      }
    }
  end

  defp wire_pairs(body, wire) do
    Enum.reduce(nodes(body), {[], []}, fn node, {calls, outputs} ->
      case {wire, node} do
        {:anthropic, %{"type" => "tool_use", "id" => id}} ->
          {[id | calls], outputs}

        {:anthropic, %{"type" => "tool_result", "tool_use_id" => id, "content" => content}} ->
          {calls, [{id, content} | outputs]}

        {:responses, %{"type" => "function_call", "call_id" => id}} ->
          {[id | calls], outputs}

        {:responses, %{"type" => "function_call_output", "call_id" => id, "output" => output}} ->
          {calls, [{id, output} | outputs]}

        {:chat, %{"id" => id, "type" => "function", "function" => _}} ->
          {[id | calls], outputs}

        {:chat, %{"role" => "tool", "tool_call_id" => id, "content" => content}} ->
          {calls, [{id, content} | outputs]}

        {:google, %{"functionCall" => %{"id" => id}}} ->
          {[id | calls], outputs}

        {:google, %{"functionResponse" => %{"id" => id, "response" => response}}} ->
          {calls, [{id, response} | outputs]}

        # Native Gemini pairs by name; Google-hosted Claude/GPT-OSS also sends IDs.
        {:google, %{"functionCall" => %{"name" => name}}} ->
          {[name | calls], outputs}

        {:google, %{"functionResponse" => %{"name" => name, "response" => response}}} ->
          {calls, [{name, response} | outputs]}

        {:bedrock, %{"toolUse" => %{"toolUseId" => id}}} ->
          {[id | calls], outputs}

        {:bedrock, %{"toolResult" => %{"toolUseId" => id, "content" => content}}} ->
          {calls, [{id, content} | outputs]}

        _ ->
          {calls, outputs}
      end
    end)
  end

  defp nodes(value) when is_map(value), do: [value | Enum.flat_map(Map.values(value), &nodes/1)]
  defp nodes(value) when is_list(value), do: Enum.flat_map(value, &nodes/1)
  defp nodes(_), do: []
end
