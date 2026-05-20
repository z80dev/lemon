Application.ensure_all_started(:lemon_control_plane)
Application.ensure_all_started(:inets)

defmodule LemonScripts.LiveOpenAICompatSmoke do
  @token "lemon-openai-compat-smoke-token"

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    project_dir = File.cwd!()

    proof_path =
      opts[:out] ||
        Path.join([project_dir, ".lemon", "proofs", "openai-compat-smoke-latest.json"])

    archive_path = archive_path(proof_path)
    port = free_port()
    parent = self()

    {:ok, requests} = Agent.start_link(fn -> [] end)
    {:ok, cancellations} = Agent.start_link(fn -> [] end)

    install_stubs(requests, cancellations, parent)

    {:ok, server} =
      Bandit.start_link(
        plug: LemonControlPlane.HTTP.Router,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    base_url = "http://127.0.0.1:#{port}"

    try do
      results = [
        check_health(base_url),
        check_waiting_chat(base_url),
        check_image_input(base_url),
        check_data_url_image_pass_through(base_url),
        check_non_vision_image_rejection(base_url, requests),
        check_remote_image_url_fetch_policy(base_url),
        check_external_fetch_client(base_url, project_dir),
        check_external_openai_sdk_client(base_url, project_dir),
        check_external_python_sdk_client(base_url, project_dir),
        check_response_continuation(base_url),
        check_stored_response(base_url),
        check_streaming_chat(base_url),
        check_run_status_redaction(base_url),
        check_cancel(base_url)
      ]

      request_summaries = Agent.get(requests, &Enum.reverse/1)
      cancellation_summaries = Agent.get(cancellations, &Enum.reverse/1)

      proof = %{
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        base_url_hash: hash(base_url),
        endpoint_count: length(results),
        completed_count: Enum.count(results, &(&1.status == "completed")),
        failed_count: Enum.count(results, &(&1.status == "failed")),
        results: results,
        request_summaries: request_summaries,
        cancellation_summaries: cancellation_summaries,
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_answers: false,
          includes_raw_events: false
        }
      }

      write_json!(proof_path, proof)
      write_json!(archive_path, proof)

      IO.puts(Jason.encode!(proof, pretty: true))

      if proof.failed_count > 0 do
        System.halt(1)
      end
    after
      if Process.alive?(server), do: GenServer.stop(server)
      Agent.stop(requests)
      Agent.stop(cancellations)
    end
  end

  defp install_stubs(requests, cancellations, parent) do
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, @token)

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      run_id = run_id_for(request)

      Agent.update(requests, fn entries ->
        [
          %{
            run_id: run_id,
            endpoint: request.meta.openai_endpoint,
            session_key_hash: hash(request.session_key),
            model: request.model,
            streaming: request.meta.streaming_requested == true,
            previous_response_id: request.meta.previous_response_id,
            image_input_count: request.meta.image_input_count || 0,
            runtime_image_count: length(request.images || [])
          }
          | entries
        ]
      end)

      if request.meta.streaming_requested == true do
        spawn(fn ->
          Process.sleep(25)
          broadcast_tool_progress(run_id)
          broadcast_delta(run_id, "stream hello")
          broadcast_completed(run_id, true, "stream hello")
        end)
      end

      send(parent, {:submitted, run_id})
      {:ok, run_id}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_waiter, fn run_id, timeout_ms ->
      send(parent, {:waited, run_id, timeout_ms})
      {:ok, %{"runId" => run_id, "ok" => true, "answer" => "waited answer", "error" => nil}}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn
      "run_stored_smoke" ->
        %{
          started_at: 1_700_000_000_000,
          events: [:started, :delta, :completed],
          summary: %{
            session_key: "agent:smoke:stored",
            model: "zai:glm-5-turbo",
            completed: %{ok: true, answer: "stored answer", error: nil}
          }
        }

      "run_active_smoke" ->
        %{started_at: 1_700_000_010_000, events: [:started], summary: nil}

      _run_id ->
        nil
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_canceller, fn run_id, reason ->
      Agent.update(cancellations, fn entries ->
        [%{run_id: run_id, reason: inspect(reason)} | entries]
      end)

      :ok
    end)
  end

  defp run_id_for(%{meta: %{openai_endpoint: "responses", previous_response_id: id}})
       when is_binary(id),
       do: "run_response_followup_smoke"

  defp run_id_for(%{meta: %{openai_endpoint: "chat.completions", streaming_requested: true}}),
    do: "run_chat_stream_smoke"

  defp run_id_for(%{meta: %{openai_endpoint: "chat.completions", image_input_count: count}})
       when count > 0,
       do: "run_chat_image_smoke"

  defp run_id_for(%{meta: %{openai_endpoint: "responses", image_input_count: count}})
       when count > 0,
       do: "run_response_image_smoke"

  defp run_id_for(%{meta: %{openai_endpoint: "chat.completions"}}),
    do: "run_chat_wait_smoke"

  defp run_id_for(%{meta: %{openai_endpoint: "responses"}}), do: "run_response_smoke"

  defp check_health(base_url) do
    with {:ok, 200, body} <- get_json(base_url, "/v1/health"),
         :ok <- require_value(body, ["status"], "ok"),
         {:ok, 200, capabilities} <- get_json(base_url, "/v1/capabilities"),
         :ok <- require_value(capabilities, ["endpoints", "tool_progress"], true),
         :ok <-
           require_value(capabilities, ["endpoints", "image_input"], "data-url-pass-through") do
      completed("health_and_capabilities")
    else
      error -> failed("health_and_capabilities", error)
    end
  end

  defp check_waiting_chat(base_url) do
    body = %{
      "model" => "zai:glm-5-turbo",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "wait" => true,
      "timeout_ms" => 1_000
    }

    with {:ok, 200, response} <- post_json(base_url, "/v1/chat/completions", body),
         :ok <- require_value(response, ["choices", Access.at(0), "finish_reason"], "stop"),
         :ok <- require_value(response, ["lemon", "status"], "completed") do
      completed("chat_wait", %{
        answer_hash: hash(get_in(response, ["choices", Access.at(0), "message", "content"]))
      })
    else
      error -> failed("chat_wait", error)
    end
  end

  defp check_image_input(base_url) do
    body = %{
      "model" => "zai:glm-5-turbo",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "describe"},
            %{
              "type" => "image_url",
              "image_url" => %{
                "url" => "https://example.test/private.png?token=secret",
                "detail" => "high"
              }
            }
          ]
        }
      ]
    }

    with {:ok, 200, response} <- post_json(base_url, "/v1/chat/completions", body),
         :ok <- require_value(response, ["lemon", "imageInputCount"], 1),
         false <- String.contains?(Jason.encode!(response), "secret") do
      completed("image_input_metadata")
    else
      true -> failed("image_input_metadata", :image_reference_leaked)
      error -> failed("image_input_metadata", error)
    end
  end

  defp check_data_url_image_pass_through(base_url) do
    image_data = Base.encode64("SMOKE_IMAGE_BYTES")

    body = %{
      "model" => "openai:gpt-4o",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "inspect"},
            %{"type" => "input_image", "image_url" => "data:image/png;base64,#{image_data}"}
          ]
        }
      ]
    }

    with {:ok, 200, response} <- post_json(base_url, "/v1/responses", body),
         :ok <- require_value(response, ["lemon", "imageInputCount"], 1),
         false <- String.contains?(Jason.encode!(response), image_data) do
      completed("data_url_image_pass_through")
    else
      true -> failed("data_url_image_pass_through", :image_bytes_leaked)
      error -> failed("data_url_image_pass_through", error)
    end
  end

  defp check_non_vision_image_rejection(base_url, requests) do
    before_count = Agent.get(requests, &length/1)
    image_data = Base.encode64("NON_VISION_SMOKE_IMAGE_BYTES")

    body = %{
      "model" => "openai:o3-mini",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "inspect"},
            %{"type" => "input_image", "image_url" => "data:image/png;base64,#{image_data}"}
          ]
        }
      ]
    }

    with {:ok, 400, response} <- post_json(base_url, "/v1/responses", body),
         :ok <- require_value(response, ["error", "message"], "model does not support image input"),
         false <- String.contains?(Jason.encode!(response), image_data),
         ^before_count <- Agent.get(requests, &length/1) do
      completed("non_vision_image_rejection")
    else
      true -> failed("non_vision_image_rejection", :image_bytes_leaked)
      after_count when is_integer(after_count) -> failed("non_vision_image_rejection", {:submitted_run, after_count})
      error -> failed("non_vision_image_rejection", error)
    end
  end

  defp check_remote_image_url_fetch_policy(base_url) do
    image_data = Base.encode64("REMOTE_SMOKE_IMAGE_BYTES")

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_fetch, true)

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts, [
      "images.example.test"
    ])

    Application.put_env(:lemon_control_plane, :openai_compat_image_url_fetcher, fn
      "https://images.example.test/private.png?token=secret", opts ->
        if opts[:max_bytes] == 20_000_000 do
          {:ok, %{mime_type: "image/png", data: image_data, byte_size: 24}}
        else
          {:error, :unexpected_max_bytes}
        end

      _url, _opts ->
        {:error, :unexpected_url}
    end)

    body = %{
      "model" => "openai:gpt-4o",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "describe"},
            %{
              "type" => "image_url",
              "image_url" => %{
                "url" => "https://images.example.test/private.png?token=secret",
                "detail" => "high"
              }
            }
          ]
        }
      ]
    }

    try do
      with {:ok, 200, response} <- post_json(base_url, "/v1/chat/completions", body),
           :ok <- require_value(response, ["lemon", "imageInputCount"], 1),
           false <- String.contains?(Jason.encode!(response), "secret"),
           false <- String.contains?(Jason.encode!(response), image_data) do
        completed("remote_image_url_fetch_policy")
      else
        true -> failed("remote_image_url_fetch_policy", :image_reference_leaked)
        error -> failed("remote_image_url_fetch_policy", error)
      end
    after
      Application.delete_env(:lemon_control_plane, :openai_compat_image_url_fetch)
      Application.delete_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts)
      Application.delete_env(:lemon_control_plane, :openai_compat_image_url_fetcher)
    end
  end

  defp check_external_fetch_client(base_url, project_dir) do
    script = Path.join([project_dir, "scripts", "live_openai_compat_fetch_client.mjs"])

    env = [
      {"LEMON_OPENAI_COMPAT_BASE_URL", base_url},
      {"LEMON_OPENAI_COMPAT_API_TOKEN", @token},
      {"LEMON_OPENAI_COMPAT_MODEL", "zai:glm-5-turbo"},
      {"LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID", "resp_run_stored_smoke"}
    ]

    with node when is_binary(node) <- System.find_executable("node"),
         {output, 0} <- System.cmd(node, [script], env: env, stderr_to_stdout: true),
         {:ok, proof} <- decode_json_output(output),
         :ok <- require_value(proof, ["failed_count"], 0),
         :ok <- require_value(proof, ["completed_count"], 7) do
      completed("external_fetch_client", %{
        proof_hash: hash(output),
        completed_count: proof["completed_count"]
      })
    else
      nil -> failed("external_fetch_client", :node_unavailable)
      {output, status} -> failed("external_fetch_client", {:exit_status, status, output})
      error -> failed("external_fetch_client", error)
    end
  end

  defp check_external_openai_sdk_client(base_url, project_dir) do
    script = Path.join([project_dir, "scripts", "live_openai_compat_openai_sdk_client.mjs"])

    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon-openai-sdk-smoke-#{System.unique_integer([:positive])}")

    env = [
      {"LEMON_OPENAI_COMPAT_BASE_URL", base_url},
      {"LEMON_OPENAI_COMPAT_API_TOKEN", @token},
      {"LEMON_OPENAI_COMPAT_MODEL", "zai:glm-5-turbo"},
      {"LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID", "resp_run_stored_smoke"}
    ]

    try do
      with node when is_binary(node) <- System.find_executable("node"),
           npm when is_binary(npm) <- System.find_executable("npm"),
           :ok <- File.mkdir_p(tmp_dir),
           {_output, 0} <- System.cmd(npm, ["init", "-y"], cd: tmp_dir, stderr_to_stdout: true),
           {_output, 0} <-
             System.cmd(npm, ["install", "openai@latest", "--no-audit", "--no-fund", "--silent"],
               cd: tmp_dir,
               stderr_to_stdout: true
             ),
         {output, 0} <-
             System.cmd(node, [script], cd: tmp_dir, env: env, stderr_to_stdout: true),
           {:ok, proof} <- decode_json_output(output),
           :ok <- require_value(proof, ["failed_count"], 0),
           :ok <- require_value(proof, ["completed_count"], 6) do
        completed("external_openai_sdk_client", %{
          proof_hash: hash(output),
          completed_count: proof["completed_count"]
        })
      else
        nil -> failed("external_openai_sdk_client", :node_or_npm_unavailable)
        {output, status} -> failed("external_openai_sdk_client", {:exit_status, status, output})
        error -> failed("external_openai_sdk_client", error)
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp check_external_python_sdk_client(base_url, project_dir) do
    script = Path.join([project_dir, "scripts", "live_openai_compat_python_sdk_client.py"])

    env = [
      {"LEMON_OPENAI_COMPAT_BASE_URL", base_url},
      {"LEMON_OPENAI_COMPAT_API_TOKEN", @token},
      {"LEMON_OPENAI_COMPAT_MODEL", "zai:glm-5-turbo"},
      {"LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID", "resp_run_stored_smoke"}
    ]

    with uv when is_binary(uv) <- System.find_executable("uv"),
         {output, 0} <-
           System.cmd(uv, ["run", "--with", "openai", "python", script],
             env: env,
             stderr_to_stdout: true
           ),
         {:ok, proof} <- decode_json_output(output),
         :ok <- require_value(proof, ["failed_count"], 0),
         :ok <- require_value(proof, ["completed_count"], 6) do
      completed("external_python_sdk_client", %{
        proof_hash: hash(output),
        completed_count: proof["completed_count"]
      })
    else
      nil -> failed("external_python_sdk_client", :uv_unavailable)
      {output, status} -> failed("external_python_sdk_client", {:exit_status, status, output})
      error -> failed("external_python_sdk_client", error)
    end
  end

  defp check_response_continuation(base_url) do
    body = %{
      "model" => "zai:glm-5-turbo",
      "input" => "continue",
      "previous_response_id" => "resp_run_stored_smoke"
    }

    with {:ok, 200, response} <- post_json(base_url, "/v1/responses", body),
         :ok <- require_value(response, ["previous_response_id"], "resp_run_stored_smoke"),
         :ok <- require_value(response, ["lemon", "previousResponseId"], "resp_run_stored_smoke") do
      completed("response_continuation")
    else
      error -> failed("response_continuation", error)
    end
  end

  defp check_stored_response(base_url) do
    with {:ok, 200, response} <- get_json(base_url, "/v1/responses/resp_run_stored_smoke"),
         :ok <- require_value(response, ["status"], "completed"),
         :ok <- require_value(response, ["lemon", "eventCount"], 3) do
      completed("stored_response", %{output_hash: hash(inspect(response["output"]))})
    else
      error -> failed("stored_response", error)
    end
  end

  defp check_streaming_chat(base_url) do
    body = %{
      "model" => "zai:glm-5-turbo",
      "messages" => [%{"role" => "user", "content" => "stream"}],
      "stream" => true
    }

    case post_raw(base_url, "/v1/chat/completions", body) do
      {:ok, 200, text}
      when is_binary(text) ->
        cond do
          not String.contains?(text, "event: lemon.tool_progress") ->
            failed("chat_stream", :missing_tool_progress)

          not String.contains?(text, "stream hello") ->
            failed("chat_stream", :missing_delta)

          not String.contains?(text, "data: [DONE]") ->
            failed("chat_stream", :missing_done)

          String.contains?(text, "raw command output") ->
            failed("chat_stream", :leaked_raw_tool_detail)

          true ->
            completed("chat_stream", %{body_hash: hash(text)})
        end

      error ->
        failed("chat_stream", error)
    end
  end

  defp check_run_status_redaction(base_url) do
    with {:ok, 200, response} <- get_json(base_url, "/v1/runs/run_stored_smoke"),
         :ok <- require_value(response, ["status"], "completed"),
         false <- String.contains?(Jason.encode!(response), "stored answer") do
      completed("run_status_redaction")
    else
      true -> failed("run_status_redaction", :answer_leaked)
      error -> failed("run_status_redaction", error)
    end
  end

  defp check_cancel(base_url) do
    with {:ok, 200, response} <- post_json(base_url, "/v1/runs/run_active_smoke/cancel", %{}),
         :ok <- require_value(response, ["status"], "cancelling") do
      completed("run_cancel")
    else
      error -> failed("run_cancel", error)
    end
  end

  defp broadcast_delta(run_id, text) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:delta, %{run_id: run_id, seq: 1, text: text}, %{run_id: run_id})
    )
  end

  defp broadcast_completed(run_id, ok, answer) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: ok, answer: answer, error: nil}}, %{
        run_id: run_id
      })
    )
  end

  defp broadcast_tool_progress(run_id) do
    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.engine_action(
        %{
          action: %{
            id: "tool_call_smoke",
            kind: "tool",
            title: "exec",
            detail: %{result: "raw command output"}
          },
          phase: :completed,
          ok: true,
          message: "tool completed"
        },
        %{run_id: run_id}
      )
    )
  end

  defp get_json(base_url, path) do
    with {:ok, status, body} <- request(:get, base_url <> path) do
      {:ok, status, Jason.decode!(body)}
    end
  end

  defp post_json(base_url, path, body) do
    with {:ok, status, body} <- post_raw(base_url, path, body) do
      {:ok, status, Jason.decode!(body)}
    end
  end

  defp post_raw(base_url, path, body) do
    request(:post, base_url <> path, Jason.encode!(body))
  end

  defp request(:get, url) do
    headers = [{~c"authorization", ~c"Bearer #{@token}"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} -> {:ok, status, body}
      error -> error
    end
  end

  defp request(:post, url, body) do
    headers = [{~c"authorization", ~c"Bearer #{@token}"}]
    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} -> {:ok, status, body}
      error -> error
    end
  end

  defp require_value(map, path, expected) do
    case get_in(map, path) do
      ^expected -> :ok
      actual -> {:unexpected_value, path, expected, actual}
    end
  end

  defp decode_json_output(output) do
    case Jason.decode(output) do
      {:ok, proof} ->
        {:ok, proof}

      {:error, _reason} ->
        output
        |> String.split("\n")
        |> Enum.drop_while(&(not String.starts_with?(String.trim_leading(&1), "{")))
        |> Enum.join("\n")
        |> Jason.decode()
    end
  end

  defp completed(name, extra \\ %{}) do
    Map.merge(%{name: name, status: "completed"}, extra)
  end

  defp failed(name, reason), do: %{name: name, status: "failed", reason: inspect(reason)}

  defp archive_path(proof_path) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    Path.join(Path.dirname(proof_path), "openai-compat-smoke-#{stamp}.json")
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonScripts.LiveOpenAICompatSmoke.main(System.argv())
