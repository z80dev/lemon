# Explicitly synthetic, offline OpenAI-compatible SSE replay. This exercises the
# production ZAI provider rather than replacing it. No request leaves this VM;
# every Req request is intercepted and an unexpected route fails closed.
defmodule LemonEvals.GlmUsageRuntimeOffline do
  def install! do
    model = LemonAi.Models.get_model(:zai, "glm-5.3")

    unless model.provider == :zai and model.api == :openai_completions and
             model.base_url == "https://api.z.ai/api/coding/paas/v4",
           do: raise("offline fixture route changed")

    Req.default_options(plug: &__MODULE__.request/1)
  end

  def request(conn) do
    unless conn.host == "api.z.ai" and
             conn.request_path == "/api/coding/paas/v4/chat/completions",
           do: raise("offline fixture rejected unexpected provider route")

    {:ok, body, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(body)
    unless body["model"] == "glm-5.3", do: raise("offline fixture rejected model switch")
    parent? = body["tools"] not in [nil, []]

    step =
      Enum.count(body["messages"] || [], fn message ->
        message["role"] == "assistant" and message["tool_calls"] not in [nil, []]
      end) + 1

    choice =
      if parent? and step <= 3 do
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "offline-read-#{step}",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => Jason.encode!(%{"path" => "config.json"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      else
        %{
          "delta" => %{"content" => "Production uses 7317; staging uses 7304."},
          "finish_reason" => "stop"
        }
      end

    fixture = System.fetch_env!("LEMON_EVAL_USAGE_FIXTURE") |> File.read!()

    usage =
      fixture
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: [DONE]" -> nil
        "data: " <> json -> Jason.decode!(json)["usage"]
        _ -> nil
      end)

    missing? = System.get_env("LEMON_EVAL_USAGE_MODE") == "missing"

    event = %{
      "id" => "offline-native-fixture",
      "model" => "glm-5.3",
      "choices" => [choice],
      "usage" => nil
    }

    terminal = %{
      "id" => "offline-native-fixture",
      "model" => "glm-5.3",
      "choices" => [],
      "usage" => usage
    }

    events = if missing?, do: [event], else: [event, terminal]

    # Safe receipt, never a prompt, credential, response body or transport header.
    receipt = %{
      fixture: true,
      provider: "zai",
      model: body["model"],
      parent: parent?,
      turn: if(parent?, do: step),
      usage_present: not missing?
    }

    File.write!(
      Path.join(System.fetch_env!("LEMON_EVAL_STATE"), "offline-requests.jsonl"),
      Jason.encode!(receipt) <> "\n",
      [:append]
    )

    sse =
      Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"

    Plug.Conn.send_resp(conn, 200, sse)
  end
end
