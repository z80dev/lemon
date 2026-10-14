defmodule LemonScripts.OAuthAuthorityProbe do
  @moduledoc false
  alias LemonAgent.ModelRuntime.{Credentials, StreamOptions}
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.{Model, UserMessage}

  # A logger handler records diagnostics without printing fixture credential bytes.
  def log(event, %{config: %{owner: owner}}), do: send(owner, {:authority_log, event})

  def run(root, provider, scenario) do
    env =
      %{
        xai: "XAI_API_KEY",
        github_copilot: "GITHUB_COPILOT_API_KEY",
        kimi_coding: "KIMI_API_KEY",
        anthropic: "ANTHROPIC_API_KEY"
      }[provider]

    api =
      if provider in [:kimi_coding, :anthropic],
        do: :anthropic_messages,
        else: :openai_completions

    secret = "selected_#{provider}_#{scenario}"
    cwd = Path.join(root, "#{provider}_#{scenario}")
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    System.put_env(env, "fixture-ambient-wrong-principal")
    System.put_env("ANTHROPIC_API_KEY", "fixture-anthropic-wrong-principal")
    System.put_env(secret, "fixture-legacy-wrong-principal")
    {:ok, _} = LemonCore.Secrets.set("llm_#{provider}_api_key", "fixture-default-wrong-principal")

    type =
      %{
        xai: "xai_oauth",
        github_copilot: "github_copilot_oauth",
        kimi_coding: "kimi_code_oauth",
        anthropic: "anthropic_oauth"
      }[provider]

    payload =
      case scenario do
        :success ->
          %{
            "type" => type,
            "access_token" => "fixture-selected-access",
            "refresh_token" => "fixture-private-refresh",
            "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
          }

        :expired ->
          %{
            "type" => type,
            "access_token" => "fixture-expired-access",
            "expires_at_ms" => 1,
            "private_marker" => "fixture-private-refresh"
          }

        :encoded ->
          %{"type" => type, "refresh_token" => "", "private_marker" => "fixture-private-refresh"}

        _ ->
          nil
      end

    if payload,
      do: LemonCore.Secrets.set(secret, Jason.encode!(payload)) |> then(fn {:ok, _} -> :ok end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn(fn -> serve(listener, owner, api) end)
    static = if scenario in [:env_only, :encoded], do: "", else: "fixture-static-wrong-principal"
    base_url = "http://127.0.0.1:#{port}/v1"

    config = %{
      "auth_source" => "oauth",
      "api_key_secret" => secret,
      "api_key" => static,
      "base_url" => base_url
    }

    File.write!(
      Path.join(cwd, ".lemon/config.toml"),
      "[providers.#{provider}]\nauth_source = \"oauth\"\napi_key_secret = \"#{secret}\"\napi_key = \"#{static}\"\nbase_url = \"#{base_url}\"\n"
    )

    providers = %{Atom.to_string(provider) => config}

    model = %Model{
      id: "fixture-authority",
      name: "Authority fixture",
      provider: provider,
      api: api,
      base_url: base_url,
      context_window: 4096,
      max_tokens: 128
    }

    handler = :oauth_authority_probe
    :ok = :logger.add_handler(handler, __MODULE__, %{level: :all, config: %{owner: owner}})

    try do
      options = StreamOptions.build_stream_options(model, providers, %{reasoning: :off}, cwd)

      loop = %AgentLoopConfig{
        model: model,
        convert_to_llm: &Function.identity/1,
        get_api_key: Credentials.build_get_api_key(providers),
        stream_options: options,
        max_retries: 0
      }

      events =
        LemonAgent.agent_loop(
          [%UserMessage{content: "Return fixture text."}],
          %AgentContext{},
          loop
        )
        |> Enum.to_list()

      # Any accepted model request is fully received before the stream can terminate.
      :logger.remove_handler(handler)
      records = drain([])
      wire = for {:wire, bytes} <- records, do: bytes
      logs = for {:log, event} <- records, do: inspect(event)

      %{
        requests: length(wire),
        selected_authority:
          Enum.all?(
            wire,
            &String.contains?(&1, [
              "Bearer fixture-selected-access\r\n",
              "x-api-key: fixture-selected-access\r\n"
            ])
          ),
        credential_leak:
          Enum.any?(
            wire ++ logs ++ [inspect(events)],
            &String.contains?(&1, [
              "fixture-private-refresh",
              "refresh_token",
              "fixture-expired-access"
            ])
          ),
        wire_credential_leak:
          Enum.any?(
            wire,
            &String.contains?(&1, [
              "fixture-private-refresh",
              "refresh_token",
              "fixture-expired-access"
            ])
          ),
        log_credential_leak:
          Enum.any?(
            logs,
            &String.contains?(&1, [
              "fixture-private-refresh",
              "refresh_token",
              "fixture-expired-access"
            ])
          ),
        event_credential_leak:
          String.contains?(inspect(events), [
            "fixture-private-refresh",
            "refresh_token",
            "fixture-expired-access"
          ]),
        wrong_principal: Enum.any?(wire, &String.contains?(&1, "wrong-principal")),
        errors:
          Enum.flat_map(events, fn
            {:error, reason, _} ->
              [safe_error(reason, root)]

            {:message_end, %{role: :assistant, stop_reason: :error, error_message: message}} ->
              [safe_error(message, root)]

            _ ->
              []
          end),
        refused:
          Enum.any?(events, fn
            {:message_end, %{stop_reason: :error}} -> true
            {:error, _, _} -> true
            _ -> false
          end),
        answered:
          Enum.any?(events, fn
            {:message_end, %{role: :assistant, content: content}} when is_list(content) ->
              Enum.any?(
                content,
                &match?(%LemonAi.Types.TextContent{text: "Authority endpoint answered."}, &1)
              )

            _ ->
              false
          end)
      }
    after
      :logger.remove_handler(handler)
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end
  end

  defp safe_error(reason, root) do
    reason
    |> inspect(limit: 10, printable_limit: 512)
    |> String.replace(root, "[fixture-root]")
    |> String.replace(~r/fixture-[a-zA-Z0-9_-]+/, "[fixture-value]")
  end

  defp drain(acc) do
    receive do
      {:authority_wire, bytes} -> drain([{:wire, bytes} | acc])
      {:authority_log, event} -> drain([{:log, event} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serve(listener, owner, api) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, body} = receive_headers(socket, "")
        [_, length] = Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers)
        body = receive_body(socket, body, String.to_integer(length))
        send(owner, {:authority_wire, headers <> "\r\n\r\n" <> body})
        response = response(api)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ",
            Integer.to_string(byte_size(response)),
            "\r\nconnection: close\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve(listener, owner, api)

      {:error, :closed} ->
        :ok
    end
  end

  defp response(:anthropic_messages) do
    events = [
      {"message_start",
       %{
         "type" => "message_start",
         "message" => %{
           "id" => "fixture",
           "type" => "message",
           "role" => "assistant",
           "content" => [],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
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
         "delta" => %{"type" => "text_delta", "text" => "Authority endpoint answered."}
       }},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
      {"message_delta",
       %{
         "type" => "message_delta",
         "delta" => %{"stop_reason" => "end_turn"},
         "usage" => %{"output_tokens" => 1}
       }},
      {"message_stop", %{"type" => "message_stop"}}
    ]

    Enum.map_join(events, fn {event, data} ->
      "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    end)
  end

  defp response(:openai_completions) do
    data =
      Jason.encode!(%{
        "id" => "fixture",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => "Authority endpoint answered."},
            "finish_reason" => "stop"
          }
        ]
      })

    "data: #{data}\n\ndata: [DONE]\n\n"
  end

  defp receive_headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, buffer <> bytes)
    end
  end

  defp receive_body(_socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp receive_body(socket, body, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    receive_body(socket, body <> bytes, length)
  end
end
