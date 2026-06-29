defmodule LemonControlPlane.HTTP.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.HTTP.Router

  setup do
    previous = Application.get_env(:lemon_control_plane, :openai_compat_submitter)
    previous_waiter = Application.get_env(:lemon_control_plane, :openai_compat_waiter)
    previous_run_getter = Application.get_env(:lemon_control_plane, :openai_compat_run_getter)
    previous_canceller = Application.get_env(:lemon_control_plane, :openai_compat_canceller)
    previous_token = Application.get_env(:lemon_control_plane, :openai_compat_api_token)

    previous_image_url_fetch =
      Application.fetch_env(:lemon_control_plane, :openai_compat_image_url_fetch)

    previous_image_url_allowed_hosts =
      Application.fetch_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts)

    previous_image_url_fetcher =
      Application.fetch_env(:lemon_control_plane, :openai_compat_image_url_fetcher)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_control_plane, :openai_compat_submitter, previous)
      else
        Application.delete_env(:lemon_control_plane, :openai_compat_submitter)
      end

      if previous_waiter do
        Application.put_env(:lemon_control_plane, :openai_compat_waiter, previous_waiter)
      else
        Application.delete_env(:lemon_control_plane, :openai_compat_waiter)
      end

      if previous_run_getter do
        Application.put_env(:lemon_control_plane, :openai_compat_run_getter, previous_run_getter)
      else
        Application.delete_env(:lemon_control_plane, :openai_compat_run_getter)
      end

      if previous_canceller do
        Application.put_env(:lemon_control_plane, :openai_compat_canceller, previous_canceller)
      else
        Application.delete_env(:lemon_control_plane, :openai_compat_canceller)
      end

      if previous_token do
        Application.put_env(:lemon_control_plane, :openai_compat_api_token, previous_token)
      else
        Application.delete_env(:lemon_control_plane, :openai_compat_api_token)
      end

      restore_env(:openai_compat_image_url_fetch, previous_image_url_fetch)
      restore_env(:openai_compat_image_url_allowed_hosts, previous_image_url_allowed_hosts)
      restore_env(:openai_compat_image_url_fetcher, previous_image_url_fetcher)
    end)

    :ok
  end

  test "serves OpenAI-compatible health and capability metadata" do
    health =
      :get
      |> conn("/v1/health")
      |> Router.call([])
      |> json_response()

    assert health.status == 200
    assert health.body["status"] == "ok"
    assert health.body["api"] == "openai-compatible-preview"

    capabilities =
      :get
      |> conn("/v1/capabilities")
      |> Router.call([])
      |> json_response()

    assert capabilities.status == 200
    assert capabilities.body["status"] == "preview"
    assert capabilities.body["endpoints"]["chat_completions"] == true
    assert capabilities.body["endpoints"]["responses"] == true
    assert capabilities.body["endpoints"]["runs"] == true
    assert capabilities.body["endpoints"]["run_cancellation"] == true
    assert capabilities.body["endpoints"]["tool_progress"] == true
    assert capabilities.body["endpoints"]["image_input"] == "data-url-pass-through"
    assert capabilities.body["endpoints"]["image_url_fetch"] == false
    assert capabilities.body["endpoints"]["image_url_fetch_policy"] == "metadata-only"
    assert capabilities.body["runtime"]["beam_supervised_runs"] == true
    assert capabilities.body["runtime"]["synchronous_wait"] == true
    assert capabilities.body["cleanup"]["includes_raw_api_keys"] == false
  end

  test "serves model list in OpenAI shape" do
    response =
      :get
      |> conn("/v1/models")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["object"] == "list"
    assert is_list(response.body["data"])
    assert Enum.any?(response.body["data"], &(&1["object"] == "model"))
    assert Enum.all?(response.body["data"], &Map.has_key?(&1, "lemon"))
    assert Enum.all?(response.body["data"], &is_boolean(&1["lemon"]["supportsVision"]))
  end

  test "serves single model metadata in OpenAI shape" do
    list =
      :get
      |> conn("/v1/models")
      |> Router.call([])
      |> json_response()

    model_id = list.body["data"] |> List.first() |> Map.fetch!("id")

    response =
      :get
      |> conn("/v1/models/#{URI.encode(model_id, &URI.char_unreserved?/1)}")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["id"] == model_id
    assert response.body["object"] == "model"
    assert Map.has_key?(response.body, "lemon")
    assert is_boolean(response.body["lemon"]["supportsVision"])

    missing =
      :get
      |> conn("/v1/models/not-a-real-lemon-model")
      |> Router.call([])
      |> json_response()

    assert missing.status == 404
    assert missing.body["error"]["message"] == "model not found"
  end

  test "OpenAI-compatible endpoints can require bearer auth" do
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, "secret-token")

    missing =
      :get
      |> conn("/v1/models")
      |> Router.call([])
      |> json_response()

    assert missing.status == 401
    assert missing.body["error"]["message"] == "authorization token is required"

    invalid =
      :get
      |> conn("/v1/models")
      |> put_req_header("authorization", "Bearer wrong")
      |> Router.call([])
      |> json_response()

    assert invalid.status == 403
    assert invalid.body["error"]["message"] == "authorization token is invalid"

    ok =
      :get
      |> conn("/v1/models")
      |> put_req_header("authorization", "Bearer secret-token")
      |> Router.call([])
      |> json_response()

    assert ok.status == 200
    assert ok.body["object"] == "list"
  end

  test "OpenAI-compatible endpoints accept x-api-key auth" do
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, "secret-token")

    response =
      :get
      |> conn("/v1/health")
      |> put_req_header("x-api-key", "secret-token")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["status"] == "ok"
  end

  test "chat completions submits a Lemon run and returns queued metadata" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_chat_123"}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [
          %{"role" => "system", "content" => "be brief"},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
        ],
        "metadata" => %{"session_key" => "agent:default:openai-test"}
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["object"] == "chat.completion"

    assert response.body["choices"] == [
             %{
               "finish_reason" => "queued",
               "index" => 0,
               "message" => %{"content" => "", "role" => "assistant"}
             }
           ]

    assert response.body["lemon"]["runId"] == "run_chat_123"
    assert response.body["lemon"]["sessionKey"] == "agent:default:openai-test"
    assert response.body["lemon"]["events"]["webSocket"] == "/ws"

    assert_receive {:submitted, request}
    assert request.origin == :control_plane
    assert request.session_key == "agent:default:openai-test"
    assert request.model == "zai:glm-5-turbo"
    assert request.meta.openai_endpoint == "chat.completions"
    assert request.meta.streaming_requested == false
    assert request.prompt == "system: be brief\nuser: hello"
  end

  test "chat completions accept redacted image input metadata" do
    parent = self()
    image_url = "https://example.test/private-image.png?token=secret"

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_chat_image_123"}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "describe this"},
              %{"type" => "image_url", "image_url" => %{"url" => image_url, "detail" => "high"}}
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["lemon"]["imageInputCount"] == 1
    refute inspect(response.body) =~ image_url
    refute inspect(response.body) =~ "secret"

    assert_receive {:submitted, request}
    assert request.prompt =~ "user: describe this\n[image input 1: kind=url"
    refute request.prompt =~ image_url
    refute request.prompt =~ "secret"
    assert request.images == []
    assert request.meta.image_input_count == 1

    assert [
             %{
               kind: "url",
               detail: "high",
               mime_type: nil,
               redacted: true,
               pass_through: false,
               sha256: sha256
             }
           ] = request.meta.openai_image_inputs

    assert is_binary(sha256)
    assert byte_size(sha256) == 16
  end

  test "chat completions can fetch allowlisted HTTPS image URLs into runtime images" do
    parent = self()
    image_url = "https://images.example.test/private-image.png?token=secret"
    image_data = Base.encode64("REMOTE_IMAGE_BYTES")

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_fetch, true)

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts, [
      "images.example.test"
    ])

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_fetcher, fn url, opts ->
      send(parent, {:fetched_image, url, opts})
      {:ok, %{mime_type: "image/png", data: image_data, byte_size: 18}}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_chat_remote_image_123"}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "openai:gpt-4o",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "describe this"},
              %{"type" => "image_url", "image_url" => %{"url" => image_url, "detail" => "high"}}
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["lemon"]["imageInputCount"] == 1
    refute inspect(response.body) =~ image_url
    refute inspect(response.body) =~ "secret"
    refute inspect(response.body) =~ image_data

    assert_receive {:fetched_image, ^image_url, opts}
    assert opts[:max_bytes] == 20_000_000

    assert_receive {:submitted, request}
    assert request.prompt =~ "user: describe this\n[image input 1: kind=url"
    assert request.prompt =~ "mime=image/png"
    refute request.prompt =~ image_url
    refute request.prompt =~ "secret"
    assert request.images == [%{data: image_data, mime_type: "image/png"}]

    assert [
             %{
               kind: "url",
               detail: "high",
               mime_type: "image/png",
               redacted: true,
               pass_through: true,
               source: "remote_fetch",
               sha256: sha256
             }
           ] = request.meta.openai_image_inputs

    assert is_binary(sha256)
    assert byte_size(sha256) == 16
  end

  test "remote image URL fetch rejects hosts outside the allowlist before submitting" do
    Application.put_env(:lemon_control_plane, :openai_compat_image_url_fetch, true)

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts, [
      "images.example.test"
    ])

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      flunk("disallowed remote image URL should not submit a run")
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "openai:gpt-4o",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "describe this"},
              %{
                "type" => "image_url",
                "image_url" => "https://blocked.example.test/private-image.png"
              }
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 400
    assert response.body["error"]["message"] == "image URL host is not allowed"
  end

  test "chat completions can stream answer deltas as SSE" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted_stream, request})

      spawn(fn ->
        Process.sleep(25)
        broadcast_tool_progress("run_chat_stream_123", "exec", "completed")
        broadcast_delta("run_chat_stream_123", "hello ")
        broadcast_delta("run_chat_stream_123", "world")
        broadcast_completed("run_chat_stream_123", true, "hello world")
      end)

      {:ok, "run_chat_stream_123"}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "stream" => true
      })
      |> Router.call([])

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["text/event-stream; charset=utf-8"]
    assert response.resp_body =~ "event: lemon.tool_progress"
    assert response.resp_body =~ "data: [DONE]"

    chunks = sse_data(response.resp_body)

    assert Enum.any?(
             chunks,
             &(&1["choices"] == [
                 %{"delta" => %{"role" => "assistant"}, "finish_reason" => nil, "index" => 0}
               ])
           )

    assert Enum.any?(
             chunks,
             &(get_in(&1, ["choices", Access.at(0), "delta", "content"]) == "hello ")
           )

    assert Enum.any?(
             chunks,
             &(get_in(&1, ["choices", Access.at(0), "delta", "content"]) == "world")
           )

    assert Enum.any?(chunks, &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == "stop"))

    assert Enum.any?(
             chunks,
             &(&1["type"] == "lemon.tool_progress" and
                 get_in(&1, ["action", "kind"]) == "tool" and
                 get_in(&1, ["action", "title"]) == "exec" and
                 &1["phase"] == "completed" and &1["ok"] == true)
           )

    refute response.resp_body =~ "raw command output"

    assert_receive {:submitted_stream, request}
    assert request.meta.streaming_requested == true
  end

  test "chat completion streams use an absolute timeout across deltas" do
    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      spawn(fn ->
        Process.sleep(10)
        broadcast_delta("run_chat_stream_timeout_123", "still ")
        Process.sleep(15)
        broadcast_delta("run_chat_stream_timeout_123", "working ")
        Process.sleep(15)
        broadcast_delta("run_chat_stream_timeout_123", "late")
      end)

      {:ok, "run_chat_stream_timeout_123"}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "stream" => true,
        "stream_timeout_ms" => 30
      })
      |> Router.call([])

    assert response.status == 200
    assert response.resp_body =~ "still "
    assert response.resp_body =~ "stream timed out"
    refute response.resp_body =~ "late"
  end

  test "chat completions can wait for a completed Lemon run" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_chat_wait_123"}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_waiter, fn run_id, timeout_ms ->
      send(parent, {:waited, run_id, timeout_ms})
      {:ok, %{"runId" => run_id, "ok" => true, "answer" => "done", "error" => nil}}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "wait" => true,
        "timeout_ms" => 1234
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert [%{"finish_reason" => "stop", "message" => message}] = response.body["choices"]
    assert message["content"] == "done"
    assert response.body["lemon"]["status"] == "completed"
    assert response.body["lemon"]["ok"] == true

    assert_receive {:submitted, _request}
    assert_receive {:waited, "run_chat_wait_123", 1234}
  end

  test "responses endpoint submits a Lemon run and returns queued response object" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_response_123"}
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:gpt-4o",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "ship it"}]
          }
        ],
        "agent_id" => "builder"
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["object"] == "response"
    assert response.body["status"] == "queued"
    assert response.body["lemon"]["runId"] == "run_response_123"
    assert response.body["lemon"]["sessionKey"] == "agent:builder:openai"

    assert_receive {:submitted, request}
    assert request.agent_id == "builder"
    assert request.prompt == "user: ship it"
    assert request.meta.openai_endpoint == "responses"
  end

  test "responses endpoint accepts redacted input image data URLs" do
    parent = self()
    image_data = Base.encode64("PRIVATE_IMAGE_BYTES")
    data_url = "data:image/png;base64,#{image_data}"

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_response_image_123"}
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:gpt-4o",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "inspect"},
              %{"type" => "input_image", "image_url" => data_url}
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["lemon"]["imageInputCount"] == 1
    refute inspect(response.body) =~ image_data

    assert_receive {:submitted, request}
    assert request.prompt =~ "user: inspect\n[image input 1: kind=data_url"
    assert request.prompt =~ "mime=image/png"
    refute request.prompt =~ image_data
    assert request.meta.image_input_count == 1
    assert request.images == [%{data: image_data, mime_type: "image/png"}]

    assert [
             %{
               kind: "data_url",
               detail: nil,
               mime_type: "image/png",
               redacted: true,
               pass_through: true,
               sha256: sha256
             }
           ] = request.meta.openai_image_inputs

    assert is_binary(sha256)
    assert byte_size(sha256) == 16
  end

  test "responses endpoint rejects runtime images for known non-vision models before submitting" do
    image_data = Base.encode64("PRIVATE_IMAGE_BYTES")
    data_url = "data:image/png;base64,#{image_data}"

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      flunk("known non-vision image input should not submit a run")
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:o3-mini",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "inspect"},
              %{"type" => "input_image", "image_url" => data_url}
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 400
    assert response.body["error"]["message"] == "model does not support image input"
    refute inspect(response.body) =~ image_data
  end

  test "responses endpoint rejects invalid data URL image inputs before submitting" do
    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      flunk("invalid image input should not submit a run")
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "zai:glm-5-turbo",
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "inspect"},
              %{"type" => "input_image", "image_url" => "data:image/png;base64,not-valid"}
            ]
          }
        ]
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 400
    assert response.body["error"]["message"] == "data URL image input must be valid base64"
  end

  test "responses endpoint continues from previous response session metadata" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn
      "run_previous_123" ->
        %{
          started_at: 1_700_000_000_000,
          events: [:started, :completed],
          summary: %{
            session_key: "agent:builder:thread",
            model: "openai:gpt-4o",
            completed: %{ok: true, answer: "prior answer", error: nil}
          }
        }

      _run_id ->
        nil
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_response_followup_123"}
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:gpt-4o",
        "input" => "continue it",
        "previous_response_id" => "resp_run_previous_123"
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["previous_response_id"] == "resp_run_previous_123"
    assert response.body["lemon"]["previousResponseId"] == "resp_run_previous_123"
    assert response.body["lemon"]["sessionKey"] == "agent:builder:thread"

    assert_receive {:submitted, request}
    assert request.session_key == "agent:builder:thread"
    assert request.meta.previous_response_id == "resp_run_previous_123"
  end

  test "responses endpoint can stream output text as SSE" do
    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      spawn(fn ->
        Process.sleep(25)
        broadcast_tool_progress("run_response_stream_123", "patch", "started")
        broadcast_delta("run_response_stream_123", "stream ")
        broadcast_delta("run_response_stream_123", "done")
        broadcast_completed("run_response_stream_123", true, "stream done")
      end)

      {:ok, "run_response_stream_123"}
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:gpt-4o",
        "input" => "ship it",
        "stream" => true
      })
      |> Router.call([])

    assert response.status == 200
    assert response.resp_body =~ "event: response.output_text.delta"
    assert response.resp_body =~ "event: response.tool_progress"
    assert response.resp_body =~ "event: response.completed"
    assert response.resp_body =~ "data: [DONE]"

    chunks = sse_data(response.resp_body)
    assert Enum.any?(chunks, &(&1["type"] == "response.created"))

    assert Enum.any?(
             chunks,
             &(&1["type"] == "response.output_text.delta" and &1["delta"] == "stream ")
           )

    assert Enum.any?(
             chunks,
             &(&1["type"] == "response.output_text.delta" and &1["delta"] == "done")
           )

    assert Enum.any?(
             chunks,
             &(&1["type"] == "response.completed" and
                 get_in(&1, ["response", "status"]) == "completed")
           )

    assert Enum.any?(
             chunks,
             &(&1["type"] == "response.tool_progress" and
                 get_in(&1, ["action", "kind"]) == "tool" and
                 get_in(&1, ["action", "title"]) == "patch" and
                 &1["phase"] == "started")
           )

    refute response.resp_body =~ "raw command output"
  end

  test "responses endpoint can wait and return output text" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_response_wait_123"}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_waiter, fn run_id, timeout_ms ->
      send(parent, {:waited, run_id, timeout_ms})
      {:ok, %{"runId" => run_id, "ok" => true, "answer" => "response done", "error" => nil}}
    end)

    response =
      :post
      |> json_conn("/v1/responses", %{
        "model" => "openai:gpt-4o",
        "input" => "ship it",
        "metadata" => %{"wait" => true, "timeoutMs" => 2345}
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["status"] == "completed"

    assert [
             %{
               "content" => [
                 %{"text" => "response done", "type" => "output_text"}
               ],
               "role" => "assistant",
               "type" => "message"
             }
           ] = response.body["output"]

    assert response.body["lemon"]["status"] == "completed"
    assert_receive {:submitted, _request}
    assert_receive {:waited, "run_response_wait_123", 2345}
  end

  test "stored response retrieval returns Responses-shaped completed output" do
    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn
      "run_response_done_123" ->
        %{
          started_at: 1_700_000_000_000,
          events: [:started, :delta, :completed],
          summary: %{
            session_key: "agent:default:openai",
            model: "zai:glm-5-turbo",
            completed: %{ok: true, answer: "stored answer", error: nil}
          }
        }

      _run_id ->
        nil
    end)

    response =
      :get
      |> conn("/v1/responses/resp_run_response_done_123")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["id"] == "resp_run_response_done_123"
    assert response.body["object"] == "response"
    assert response.body["status"] == "completed"
    assert response.body["model"] == "zai:glm-5-turbo"

    assert [
             %{
               "content" => [
                 %{"text" => "stored answer", "type" => "output_text"}
               ],
               "role" => "assistant",
               "type" => "message"
             }
           ] = response.body["output"]

    assert response.body["lemon"]["runId"] == "run_response_done_123"
    assert response.body["lemon"]["eventCount"] == 3
  end

  test "stored response retrieval rejects unknown response ids" do
    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn _run_id -> nil end)

    response =
      :get
      |> conn("/v1/responses/resp_missing")
      |> Router.call([])
      |> json_response()

    assert response.status == 404
    assert response.body["error"]["message"] == "response not found"
  end

  test "wait timeout returns a gateway timeout error" do
    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn _request ->
      {:ok, "run_timeout_123"}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_waiter, fn _run_id, _timeout_ms ->
      {:error, :timeout}
    end)

    response =
      :post
      |> json_conn("/v1/chat/completions", %{
        "model" => "zai:glm-5-turbo",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "wait" => true
      })
      |> Router.call([])
      |> json_response()

    assert response.status == 504
    assert response.body["error"]["message"] == "Run did not complete within timeout"
    assert response.body["error"]["type"] == "server_error"
  end

  test "run status returns redacted run metadata" do
    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn
      "run_done_123" ->
        %{
          started_at: 1_700_000_000_000,
          events: [:started, :delta],
          summary: %{
            session_key: "agent:default:openai",
            completed_at_ms: 1_700_000_001_000,
            completed: %{ok: true, answer: "private answer", error: nil}
          }
        }

      _run_id ->
        nil
    end)

    response =
      :get
      |> conn("/v1/runs/run_done_123")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["id"] == "run_done_123"
    assert response.body["object"] == "run"
    assert response.body["status"] == "completed"
    assert response.body["created_at"] == 1_700_000_000
    assert response.body["completed_at"] == 1_700_000_001
    assert response.body["lemon"]["sessionKey"] == "agent:default:openai"
    assert response.body["lemon"]["eventCount"] == 2
    assert response.body["lemon"]["ok"] == true
    refute inspect(response.body) =~ "private answer"
  end

  test "run status returns not found for unknown runs" do
    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn _run_id -> nil end)

    response =
      :get
      |> conn("/v1/runs/missing")
      |> Router.call([])
      |> json_response()

    assert response.status == 404
    assert response.body["error"]["message"] == "run not found"
  end

  test "run cancel calls router abort for non-terminal runs" do
    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn "run_active_123" ->
      %{started_at: 1_700_000_000_000, events: [:started], summary: nil}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_canceller, fn run_id, reason ->
      send(parent, {:cancelled, run_id, reason})
      :ok
    end)

    response =
      :post
      |> conn("/v1/runs/run_active_123/cancel")
      |> Router.call([])
      |> json_response()

    assert response.status == 200
    assert response.body["status"] == "cancelling"
    assert response.body["lemon"]["eventCount"] == 1
    assert_receive {:cancelled, "run_active_123", :openai_compat_cancel}
  end

  test "chat completions validates required fields" do
    response =
      :post
      |> json_conn("/v1/chat/completions", %{"model" => "zai:glm-5-turbo"})
      |> Router.call([])
      |> json_response()

    assert response.status == 400
    assert response.body["error"]["message"] == "messages must be a non-empty array"
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp json_response(conn) do
    %{status: conn.status, body: Jason.decode!(conn.resp_body)}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_control_plane, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_control_plane, key)

  defp broadcast_delta(run_id, text) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(
        :delta,
        %{run_id: run_id, seq: System.unique_integer([:positive]), text: text},
        %{
          run_id: run_id,
          session_key: "agent:default:openai"
        }
      )
    )
  end

  defp broadcast_completed(run_id, ok, answer) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(
        :run_completed,
        %{completed: %{ok: ok, answer: answer, error: nil}, duration_ms: 1},
        %{run_id: run_id, session_key: "agent:default:openai"}
      )
    )
  end

  defp broadcast_tool_progress(run_id, title, phase) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.engine_action(
        %{
          engine: "lemon",
          action: %{
            id: "tool_call_#{title}",
            kind: "tool",
            title: title,
            detail: %{result: "raw command output"}
          },
          phase: String.to_atom(phase),
          ok: phase == "completed",
          message: "tool #{phase}"
        },
        %{run_id: run_id, session_key: "agent:default:openai"}
      )
    )
  end

  defp sse_data(body) do
    ~r/^data: (.+)$/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.map(&Jason.decode!/1)
  end
end
