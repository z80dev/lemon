unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

Application.ensure_all_started(:lemon_control_plane)
Application.ensure_all_started(:inets)

defmodule LemonScripts.LiveOpenAICompatVisionSmoke do
  @token "lemon-openai-compat-vision-smoke-token"
  @red_png_base64 "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgAQMAAABJtOi3AAAAA1BMVEX/AAAZ4gk3AAAADElEQVQI12NgGNwAAACgAAFhJX1HAAAAAElFTkSuQmCC"
  @default_models [
    "openrouter:openai/gpt-4o-mini",
    "openai:gpt-4o-mini",
    "zai:glm-4.6v"
  ]

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string, model: :string])

    project_dir = File.cwd!()

    proof_path =
      opts[:out] ||
        Path.join([project_dir, ".lemon", "proofs", "openai-compat-vision-smoke-latest.json"])

    archive_path = archive_path(proof_path)

    case live_config(opts) do
      {:skip, reason} ->
        proof = proof(:skipped, %{reason: reason})
        write_json!(proof_path, proof)
        write_json!(archive_path, proof)
        IO.puts(Jason.encode!(proof, pretty: true))

      {:ok, model} ->
        run_smoke(model, proof_path, archive_path, project_dir)
    end
  end

  defp run_smoke(model, proof_path, archive_path, project_dir) do
    port = free_port()
    previous_token = Application.fetch_env(:lemon_control_plane, :openai_compat_api_token)
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, @token)

    {:ok, server} =
      Bandit.start_link(
        plug: LemonControlPlane.HTTP.Router,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    base_url = "http://127.0.0.1:#{port}"

    proof =
      try do
        case check_vision(base_url, model, project_dir) do
          {:ok, details} -> proof(:completed, details)
          {:error, reason} -> proof(:failed, %{reason: inspect(reason)})
        end
      after
        if Process.alive?(server), do: GenServer.stop(server)
        restore_env(:openai_compat_api_token, previous_token)
      end

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp check_vision(base_url, model, project_dir) do
    body = %{
      "model" => model,
      "wait" => true,
      "timeout_ms" => 120_000,
      "metadata" => %{
        "session_key" => "agent:default:openai-vision-smoke"
      },
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "Look at the image. Reply with exactly one lowercase color word."
            },
            %{
              "type" => "input_image",
              "image_url" => "data:image/png;base64,#{@red_png_base64}"
            }
          ]
        }
      ]
    }

    with {:ok, 200, response} <- post_json(base_url, "/v1/responses", body),
         :ok <- require_value(response, ["status"], "completed"),
         :ok <- require_value(response, ["lemon", "ok"], true),
         :ok <- require_value(response, ["lemon", "imageInputCount"], 1),
         answer when is_binary(answer) <- output_text(response),
         true <- String.contains?(String.downcase(answer), "red"),
         {:ok, external_fetch_client} <- check_external_fetch_vision(base_url, model, project_dir),
         {:ok, external_openai_sdk_client} <-
           check_external_openai_sdk_vision(base_url, model, project_dir) do
      {:ok,
       %{
         model: model,
         response_id_hash: hash(response["id"]),
         run_id_hash: hash(get_in(response, ["lemon", "runId"])),
         answer_hash: hash(answer),
         answer_matched_red: true,
         external_fetch_client: external_fetch_client,
         external_openai_sdk_client: external_openai_sdk_client
       }}
    else
      false -> {:error, :answer_did_not_identify_red}
      nil -> {:error, :missing_answer}
      error -> {:error, error}
    end
  end

  defp check_external_fetch_vision(base_url, model, project_dir) do
    script = Path.join([project_dir, "scripts", "live_openai_compat_fetch_client.mjs"])

    env = [
      {"LEMON_OPENAI_COMPAT_BASE_URL", base_url},
      {"LEMON_OPENAI_COMPAT_API_TOKEN", @token},
      {"LEMON_OPENAI_COMPAT_MODEL", model},
      {"LEMON_OPENAI_COMPAT_CHECKS", "vision"},
      {"LEMON_OPENAI_COMPAT_IMAGE_BASE64", @red_png_base64}
    ]

    with node when is_binary(node) <- System.find_executable("node"),
         {output, 0} <- System.cmd(node, [script], env: env, stderr_to_stdout: true),
         {:ok, proof} <- Jason.decode(output),
         :ok <- require_value(proof, ["check_mode"], "vision"),
         :ok <- require_value(proof, ["failed_count"], 0),
         :ok <- require_value(proof, ["completed_count"], 1) do
      {:ok,
       %{
         proof_hash: hash(output),
         completed_count: proof["completed_count"],
         answer_matched_red:
           get_in(proof, ["results", Access.at(0), "answer_matched_red"]) == true
       }}
    else
      nil -> {:error, :node_unavailable}
      {output, status} -> {:error, {:external_fetch_client_exit, status, output}}
      error -> {:error, {:external_fetch_client, error}}
    end
  end

  defp check_external_openai_sdk_vision(base_url, model, project_dir) do
    script = Path.join([project_dir, "scripts", "live_openai_compat_openai_sdk_client.mjs"])

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-openai-sdk-vision-smoke-#{System.unique_integer([:positive])}"
      )

    env = [
      {"LEMON_OPENAI_COMPAT_BASE_URL", base_url},
      {"LEMON_OPENAI_COMPAT_API_TOKEN", @token},
      {"LEMON_OPENAI_COMPAT_MODEL", model},
      {"LEMON_OPENAI_COMPAT_CHECKS", "vision"},
      {"LEMON_OPENAI_COMPAT_IMAGE_BASE64", @red_png_base64}
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
           {:ok, proof} <- Jason.decode(output),
           :ok <- require_value(proof, ["check_mode"], "vision"),
           :ok <- require_value(proof, ["failed_count"], 0),
           :ok <- require_value(proof, ["completed_count"], 1) do
        {:ok,
         %{
           proof_hash: hash(output),
           completed_count: proof["completed_count"],
           answer_matched_red:
             get_in(proof, ["results", Access.at(0), "answer_matched_red"]) == true
         }}
      else
        nil -> {:error, :node_or_npm_unavailable}
        {output, status} -> {:error, {:external_openai_sdk_client_exit, status, output}}
        error -> {:error, {:external_openai_sdk_client, error}}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp live_config(opts) do
    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run provider-backed vision proof"}

      true ->
        model = configured_model(opts) || default_model_with_credentials()

        cond do
          blank?(model) ->
            {:skip,
             "set --model or LEMON_OPENAI_COMPAT_LIVE_VISION_MODEL to a vision-capable Lemon model"}

          provider_credential_available?(model) ->
            {:ok, model}

          true ->
            {:skip, "no configured credential resolved for #{model_provider(model) || "model"}"}
        end
    end
  end

  defp configured_model(opts) do
    (opts[:model] || System.get_env("LEMON_OPENAI_COMPAT_LIVE_VISION_MODEL"))
    |> case do
      model when is_binary(model) -> String.trim(model)
      _other -> nil
    end
    |> reject_blank()
  end

  defp default_model_with_credentials do
    Enum.find(@default_models, &provider_credential_available?/1)
  end

  defp reject_blank(value), do: if(blank?(value), do: nil, else: value)

  defp provider_credential_available?(model) do
    case model_provider(model) do
      nil ->
        false

      provider ->
        cfg = LemonCore.Config.load(File.cwd!())
        AgentCore.ModelRuntime.Credentials.provider_has_credentials?(provider, cfg.providers, cwd: File.cwd!())
    end
  end

  defp model_provider(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model_id] -> provider
      _other -> nil
    end
  end

  defp post_json(base_url, path, body) do
    url = String.to_charlist(base_url <> path)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", ~c"Bearer #{@token}"}
    ]

    request = {url, headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [timeout: 130_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:ok, status, Jason.decode!(response_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_value(body, path, expected) do
    case get_in(body, path) do
      ^expected -> :ok
      value -> {:error, {:unexpected_value, path, expected, value}}
    end
  end

  defp output_text(response) do
    response
    |> get_in(["output", Access.at(0), "content"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _other -> nil
    end)
  end

  defp proof(:completed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:skipped, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "skipped",
      completed_count: 0,
      skipped_count: 1,
      failed_count: 0,
      details: details,
      cleanup: cleanup()
    }
  end

  defp cleanup do
    %{
      includes_raw_api_keys: false,
      includes_raw_prompts: false,
      includes_raw_answers: false,
      includes_raw_image_bytes: false
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp archive_path(path) do
    root = Path.rootname(path)
    ext = Path.extname(path)
    "#{root}-#{DateTime.utc_now() |> DateTime.to_unix(:millisecond)}#{ext}"
  end

  defp write_json!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp hash(nil), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_control_plane, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_control_plane, key)

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end

LemonScripts.LiveOpenAICompatVisionSmoke.main(System.argv())
