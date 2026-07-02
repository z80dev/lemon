defmodule LemonSkills.Tools.MediaGenerateVideo do
  @moduledoc """
  Supervised video-generation preview tool backed by LemonMedia.MediaJobSupervisor.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias AgentCore.Tools.AbortHelpers
  alias AgentCore.ModelRuntime.ProviderNames
  alias LemonCore.Config
  alias LemonMedia.MediaJobSupervisor
  alias LemonMedia.MediaJobs
  alias LemonCore.ProviderConfigResolver

  @topic "media_jobs"
  @default_timeout_ms 20_000
  @max_timeout_ms 300_000
  @local_provider "local_mp4"
  @openai_provider "openai_video"
  @vertex_provider "vertex_veo"
  @local_model "local_mp4_preview"
  @default_openai_model "sora-2"
  @default_vertex_model "veo-3.1-fast-generate-001"
  @default_openai_base_url "https://api.openai.com/v1"
  @default_vertex_location "us-central1"
  @formats %{"mp4" => "video/mp4"}
  @local_mp4_preview <<0, 0, 0, 24, "ftypmp42", 0, 0, 0, 0, "mp42isom", 0, 0, 0, 8, "free">>

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_generate_video",
      description:
        "Generate a supervised video through Lemon's BEAM media worker path. Supports deterministic local MP4 previews, OpenAI video job create/poll/download, and Vertex AI Veo long-running prediction, records redacted media-job metadata, and can opt into final Telegram/Discord attachment delivery.",
      label: "Media Generate Video",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" => "Video prompt. Stored only as redacted metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider, @vertex_provider],
            "description" =>
              "Video provider. local_mp4 is deterministic; openai_video uses OpenAI video credentials; vertex_veo uses Google Vertex AI Veo credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_mp4_preview, sora-2, or veo-3.1-fast-generate-001."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "size" => %{
            "type" => "string",
            "description" => "Optional provider video size, for example 1280x720."
          },
          "seconds" => %{
            "type" => "string",
            "description" => "Optional provider duration in seconds."
          },
          "storageUri" => %{
            "type" => "string",
            "description" =>
              "Optional Vertex Veo Google Cloud Storage output URI. When omitted, Lemon expects inline video bytes from the operation response."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" =>
              "Maximum transient provider retries for OpenAI video create/status/download calls."
          },
          "maxPolls" => %{
            "type" => "integer",
            "description" => "Maximum OpenAI video status polls before failing the job."
          },
          "pollIntervalMs" => %{
            "type" => "integer",
            "description" => "Delay between OpenAI video status polls."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" =>
              "When true, request final Telegram/Discord video attachment delivery."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Maximum time to wait for the supervised media worker."
          }
        },
        "required" => ["prompt"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, prompt} <- required_prompt(params),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <- timeout_ms(params),
         {:ok, artifact_path} <- artifact_path(params, cwd, opts, generation.format),
         :ok <- Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic),
         {:ok, _pid, queued_job} <-
           MediaJobSupervisor.start_job(
             %{
               type: :video,
               provider: provider,
               model: generation.model,
               prompt: prompt,
               artifact_name: Path.basename(artifact_path),
               mime_type: generation.mime_type
             },
             media_job_opts(cwd, opts, artifact_path, generation)
           ),
         :ok <- AbortHelpers.check_abort(signal),
         {:ok, completed_job} <- wait_for_job(queued_job.job_id, timeout_ms, signal) do
      payload = payload(completed_job, artifact_path, params)

      %AgentToolResult{
        content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
        details: payload
      }
    end
  end

  defp required_prompt(%{"prompt" => prompt}) when is_binary(prompt) do
    prompt = String.trim(prompt)
    if prompt == "", do: {:error, "prompt is required"}, else: {:ok, prompt}
  end

  defp required_prompt(_params), do: {:error, "prompt is required"}

  defp provider(params) do
    case Map.get(params, "provider", @local_provider) do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      @vertex_provider -> {:ok, @vertex_provider}
      other when is_binary(other) -> {:error, "unsupported media video provider: #{other}"}
      _other -> {:error, "provider must be a string"}
    end
  end

  defp generation(@local_provider, _params) do
    {:ok,
     %{
       provider: @local_provider,
       model: @local_model,
       format: "mp4",
       mime_type: "video/mp4"
     }}
  end

  defp generation(@openai_provider, params) do
    {:ok,
     %{
       provider: @openai_provider,
       model: optional_string(params["model"]) || @default_openai_model,
       format: "mp4",
       mime_type: "video/mp4",
       size: optional_string(params["size"]),
       seconds: optional_string(params["seconds"]),
       max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3),
       max_polls: bounded_integer(Map.get(params, "maxPolls", 30), 1, 120),
       poll_interval_ms: bounded_integer(Map.get(params, "pollIntervalMs", 2_000), 0, 30_000)
     }}
  end

  defp generation(@vertex_provider, params) do
    {:ok,
     %{
       provider: @vertex_provider,
       model: optional_string(params["model"]) || @default_vertex_model,
       format: "mp4",
       mime_type: "video/mp4",
       size: optional_string(params["size"]),
       seconds: optional_string(params["seconds"]),
       storage_uri: optional_string(params["storageUri"] || params["storage_uri"]),
       max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3),
       max_polls: bounded_integer(Map.get(params, "maxPolls", 30), 1, 120),
       poll_interval_ms: bounded_integer(Map.get(params, "pollIntervalMs", 2_000), 0, 30_000)
     }}
  end

  defp timeout_ms(params) do
    value = Map.get(params, "timeoutMs", @default_timeout_ms)

    cond do
      is_integer(value) -> {:ok, value |> max(100) |> min(@max_timeout_ms)}
      is_binary(value) -> parse_timeout(value)
      true -> {:error, "timeoutMs must be an integer"}
    end
  end

  defp parse_timeout(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int |> max(100) |> min(@max_timeout_ms)}
      _ -> {:error, "timeoutMs must be an integer"}
    end
  end

  defp artifact_path(params, cwd, opts, format) do
    artifacts_dir =
      opts
      |> Keyword.get(:media_artifacts_dir, MediaJobs.default_artifacts_dir(cwd))
      |> Path.expand()

    name =
      params
      |> Map.get("filename")
      |> sanitize_filename(format)

    path = Path.join(artifacts_dir, name)

    if String.starts_with?(Path.expand(path), artifacts_dir) do
      {:ok, path}
    else
      {:error, "artifact path escaped media artifact directory"}
    end
  end

  defp sanitize_filename(nil, format), do: default_filename(format)

  defp sanitize_filename(value, format) when is_binary(value) do
    value
    |> Path.basename()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 96)
    |> case do
      "" -> default_filename(format)
      name -> ensure_extension(name, format)
    end
  end

  defp sanitize_filename(_value, format), do: default_filename(format)

  defp default_filename(format) do
    "media-video-#{System.unique_integer([:positive])}.#{format}"
  end

  defp ensure_extension(name, format) do
    if String.downcase(Path.extname(name)) == ".#{format}" do
      name
    else
      "#{Path.rootname(name)}.#{format}"
    end
  end

  defp media_job_opts(cwd, opts, artifact_path, generation) do
    [
      project_dir: cwd,
      dir: Keyword.get(opts, :media_jobs_dir),
      artifacts_dir: Path.dirname(artifact_path),
      runner: runner(cwd, opts, artifact_path, generation)
    ]
  end

  defp runner(_cwd, _opts, artifact_path, %{provider: @local_provider}) do
    &run_local_video(&1, artifact_path)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @openai_provider} = generation) do
    runtime = openai_runtime(cwd, opts)
    &run_openai_video(&1, artifact_path, generation, runtime)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @vertex_provider} = generation) do
    runtime = vertex_runtime(cwd, opts)
    &run_vertex_veo(&1, artifact_path, generation, runtime)
  end

  defp run_local_video(_attrs, artifact_path) do
    with :ok <- write_file(artifact_path, @local_mp4_preview),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: "video/mp4",
         bytes: stat.size
       }}
    end
  end

  defp run_openai_video(attrs, artifact_path, generation, runtime) do
    with {:ok, api_key} <- openai_api_key(runtime),
         {:ok, video} <- create_openai_video(attrs, generation, runtime, api_key),
         {:ok, completed} <- wait_openai_video(video, generation, runtime, api_key),
         {:ok, bytes} <- download_openai_video(completed, generation, runtime, api_key),
         :ok <- write_file(artifact_path, bytes),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: "video/mp4",
         bytes: stat.size,
         provider_job_id: redacted_video_id(completed)
       }}
    end
  end

  defp run_vertex_veo(attrs, artifact_path, generation, runtime) do
    with {:ok, access_token} <- vertex_access_token(runtime),
         {:ok, operation} <- create_vertex_veo(attrs, generation, runtime, access_token),
         {:ok, completed} <- wait_vertex_veo(operation, generation, runtime, access_token),
         {:ok, {bytes, mime_type}} <- decode_vertex_veo_response(completed, generation.mime_type),
         :ok <- write_file(artifact_path, bytes),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: mime_type,
         bytes: stat.size,
         provider_job_id: redacted_operation_name(completed)
       }}
    end
  end

  defp openai_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_video_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :openai) || %{}

    %{
      api_key: Keyword.get(opts, :openai_video_api_key),
      base_url:
        Keyword.get(opts, :openai_video_base_url) ||
          optional_string(provider_config_value(provider_cfg, :base_url)) ||
          @default_openai_base_url,
      provider_cfg: provider_cfg,
      http_post: Keyword.get(opts, :media_video_http_post, &Req.post/2),
      http_get: Keyword.get(opts, :media_video_http_get, &Req.get/2)
    }
  end

  defp openai_api_key(%{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}

  defp openai_api_key(%{provider_cfg: provider_cfg}) do
    case AgentCore.ModelRuntime.Credentials.resolve_provider_api_key(:openai, provider_cfg,
           provider_cfg: true
         ) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_openai_video_api_key}
    end
  end

  defp vertex_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_video_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderConfigResolver.resolve_for_provider(
        :google_vertex,
        Map.merge(provider_cfg, %{cwd: cwd})
      )

    %{
      access_token: Keyword.get(opts, :vertex_veo_access_token),
      project: Keyword.get(opts, :vertex_veo_project) || resolved[:project],
      location:
        Keyword.get(opts, :vertex_veo_location) ||
          resolved[:location] ||
          @default_vertex_location,
      service_account_json:
        Keyword.get(opts, :vertex_veo_service_account_json) ||
          resolved[:service_account_json],
      http_post: Keyword.get(opts, :media_video_http_post, &Req.post/2),
      token_http_post: Keyword.get(opts, :vertex_token_http_post, &Req.post/2)
    }
  end

  defp vertex_access_token(%{access_token: token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp vertex_access_token(%{service_account_json: json} = runtime)
       when is_binary(json) and json != "" do
    with {:ok, credentials} <- Jason.decode(json),
         {:ok, jwt, token_uri} <- vertex_service_account_jwt(credentials),
         {:ok, token} <- exchange_vertex_jwt(jwt, token_uri, runtime) do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_vertex_veo_service_account_json}
    end
  end

  defp vertex_access_token(_runtime), do: {:error, :missing_vertex_veo_credentials}

  defp vertex_service_account_jwt(credentials) do
    client_email = credentials["client_email"]
    private_key = credentials["private_key"]
    token_uri = credentials["token_uri"] || "https://oauth2.googleapis.com/token"

    if is_binary(client_email) and client_email != "" and is_binary(private_key) and
         private_key != "" do
      now = System.system_time(:second)

      header = %{"alg" => "RS256", "typ" => "JWT"}

      claims = %{
        "iss" => client_email,
        "sub" => client_email,
        "scope" => "https://www.googleapis.com/auth/cloud-platform",
        "aud" => token_uri,
        "iat" => now,
        "exp" => now + 3600
      }

      signing_input =
        Base.url_encode64(Jason.encode!(header), padding: false) <>
          "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

      with [pem_entry | _] <- :public_key.pem_decode(private_key),
           private_key <- :public_key.pem_entry_decode(pem_entry) do
        signature = :public_key.sign(signing_input, :sha256, private_key)
        jwt = signing_input <> "." <> Base.url_encode64(signature, padding: false)
        {:ok, jwt, token_uri}
      else
        _ -> {:error, :invalid_vertex_veo_service_account_private_key}
      end
    else
      {:error, :invalid_vertex_veo_service_account_json}
    end
  end

  defp exchange_vertex_jwt(jwt, token_uri, runtime) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    request_opts = [
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: body,
      receive_timeout: 60_000
    ]

    case runtime.token_http_post.(token_uri, request_opts) do
      {:ok, %{status: status, body: %{"access_token" => token}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:vertex_veo_token_http_error, status, provider_error_kind(response_body)}}

      {:error, reason} ->
        {:error, {:vertex_veo_token_request_failed, provider_error_kind(reason)}}
    end
  end

  defp create_openai_video(attrs, generation, runtime, api_key) do
    prompt = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
    url = String.trim_trailing(runtime.base_url, "/") <> "/videos"

    body =
      %{
        "model" => generation.model,
        "prompt" => prompt,
        "size" => generation.size,
        "seconds" => generation.seconds
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    do_post(runtime, url, request_opts, generation.max_retries, :openai_video_create)
  end

  defp wait_openai_video(video, generation, runtime, api_key) do
    case video_status(video) do
      status when status in ["completed", "succeeded"] ->
        {:ok, video}

      status when status in ["failed", "cancelled"] ->
        {:error, {:openai_video_failed, status, provider_error_kind(video)}}

      _status ->
        poll_openai_video(video_id(video), generation, runtime, api_key, generation.max_polls)
    end
  end

  defp poll_openai_video(nil, _generation, _runtime, _api_key, _remaining) do
    {:error, :missing_openai_video_id}
  end

  defp poll_openai_video(_id, _generation, _runtime, _api_key, 0) do
    {:error, :openai_video_poll_exhausted}
  end

  defp poll_openai_video(id, generation, runtime, api_key, remaining) do
    if generation.poll_interval_ms > 0, do: Process.sleep(generation.poll_interval_ms)

    url = String.trim_trailing(runtime.base_url, "/") <> "/videos/" <> id

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      receive_timeout: 300_000
    ]

    with {:ok, video} <-
           do_get(runtime, url, request_opts, generation.max_retries, :openai_video_status) do
      case video_status(video) do
        status when status in ["completed", "succeeded"] ->
          {:ok, video}

        status when status in ["failed", "cancelled"] ->
          {:error, {:openai_video_failed, status, provider_error_kind(video)}}

        _status ->
          poll_openai_video(id, generation, runtime, api_key, remaining - 1)
      end
    end
  end

  defp download_openai_video(video, generation, runtime, api_key) do
    with id when is_binary(id) <- video_id(video) do
      url = String.trim_trailing(runtime.base_url, "/") <> "/videos/" <> id <> "/content"

      request_opts = [
        headers: [{"authorization", "Bearer #{api_key}"}],
        receive_timeout: 300_000
      ]

      do_get(runtime, url, request_opts, generation.max_retries, :openai_video_download)
    else
      _ -> {:error, :missing_openai_video_id}
    end
  end

  defp create_vertex_veo(attrs, generation, runtime, access_token) do
    with {:ok, project} <- required_vertex_value(runtime.project, :missing_vertex_veo_project),
         {:ok, location} <- required_vertex_value(runtime.location, :missing_vertex_veo_location) do
      prompt = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

      url =
        "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{generation.model}:predictLongRunning"

      parameters =
        %{
          "sampleCount" => 1,
          "durationSeconds" => vertex_duration(generation.seconds),
          "aspectRatio" => vertex_aspect_ratio(generation.size),
          "storageUri" => generation.storage_uri
        }
        |> reject_blank_values()

      body = %{
        "instances" => [%{"prompt" => prompt}],
        "parameters" => parameters
      }

      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: body,
        receive_timeout: 300_000
      ]

      do_post(runtime, url, request_opts, generation.max_retries, :vertex_veo_create)
    end
  end

  defp wait_vertex_veo(operation, generation, runtime, access_token) do
    cond do
      operation_done?(operation) and operation_error(operation) ->
        {:error, {:vertex_veo_failed, provider_error_kind(operation_error(operation))}}

      operation_done?(operation) ->
        {:ok, operation}

      true ->
        poll_vertex_veo(
          operation_name(operation),
          generation,
          runtime,
          access_token,
          generation.max_polls
        )
    end
  end

  defp poll_vertex_veo(nil, _generation, _runtime, _access_token, _remaining) do
    {:error, :missing_vertex_veo_operation_name}
  end

  defp poll_vertex_veo(_operation_name, _generation, _runtime, _access_token, 0) do
    {:error, :vertex_veo_poll_exhausted}
  end

  defp poll_vertex_veo(operation_name, generation, runtime, access_token, remaining) do
    if generation.poll_interval_ms > 0, do: Process.sleep(generation.poll_interval_ms)

    with {:ok, project} <- required_vertex_value(runtime.project, :missing_vertex_veo_project),
         {:ok, location} <- required_vertex_value(runtime.location, :missing_vertex_veo_location) do
      url =
        "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{generation.model}:fetchPredictOperation"

      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: %{"operationName" => operation_name},
        receive_timeout: 300_000
      ]

      with {:ok, operation} <-
             do_post(runtime, url, request_opts, generation.max_retries, :vertex_veo_status) do
        cond do
          operation_done?(operation) and operation_error(operation) ->
            {:error, {:vertex_veo_failed, provider_error_kind(operation_error(operation))}}

          operation_done?(operation) ->
            {:ok, operation}

          true ->
            poll_vertex_veo(operation_name, generation, runtime, access_token, remaining - 1)
        end
      end
    end
  end

  defp required_vertex_value(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp required_vertex_value(_value, reason), do: {:error, reason}

  defp do_post(runtime, url, request_opts, retries, error_kind) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        retry_or_error(
          fn -> do_post(runtime, url, request_opts, retries - 1, error_kind) end,
          retries,
          error_kind,
          status,
          body
        )

      {:error, _reason} when retries > 0 ->
        do_post(runtime, url, request_opts, retries - 1, error_kind)

      {:error, reason} ->
        {:error, {:"#{error_kind}_request_failed", provider_error_kind(reason)}}
    end
  end

  defp do_get(runtime, url, request_opts, retries, error_kind) do
    case runtime.http_get.(url, request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        retry_or_error(
          fn -> do_get(runtime, url, request_opts, retries - 1, error_kind) end,
          retries,
          error_kind,
          status,
          body
        )

      {:error, _reason} when retries > 0 ->
        do_get(runtime, url, request_opts, retries - 1, error_kind)

      {:error, reason} ->
        {:error, {:"#{error_kind}_request_failed", provider_error_kind(reason)}}
    end
  end

  defp retry_or_error(retry_fun, retries, error_kind, status, body) do
    if is_transient_status(status) and retries > 0 do
      retry_fun.()
    else
      {:error, {:"#{error_kind}_http_error", status, provider_error_kind(body)}}
    end
  end

  defp is_transient_status(status) when status in [408, 409, 425, 429], do: true
  defp is_transient_status(status) when is_integer(status) and status >= 500, do: true
  defp is_transient_status(_status), do: false

  defp wait_for_job(job_id, timeout_ms, signal) do
    receive do
      {:media_job, :completed, %{job_id: ^job_id} = job} ->
        {:ok, job}

      {:media_job, :failed, %{job_id: ^job_id} = job} ->
        {:error, "media job failed: #{Map.get(job, :error_kind, "unknown")}"}

      {:media_job, _event, %{job_id: ^job_id}} ->
        case AbortHelpers.check_abort(signal) do
          :ok -> wait_for_job(job_id, timeout_ms, signal)
          {:error, reason} -> {:error, reason}
        end

      _other ->
        wait_for_job(job_id, timeout_ms, signal)
    after
      timeout_ms -> {:error, "media job timed out after #{timeout_ms}ms"}
    end
  end

  defp payload(job, artifact_path, params) do
    artifact_name = get_in(job, [:artifact, :name]) || Path.basename(artifact_path)
    mime_type = get_in(job, [:artifact, :mime_type]) || mime_type_from_path(artifact_path)

    artifact = %{
      "path" => artifact_path,
      "filename" => artifact_name,
      "mime_type" => mime_type,
      "bytes" => artifact_bytes(artifact_path)
    }

    %{
      "job_id" => job.job_id,
      "status" => Atom.to_string(job.status),
      "type" => Atom.to_string(job.type),
      "provider" => job.provider,
      "model" => job.model,
      "prompt_hash" => job.prompt_hash,
      "prompt_chars" => job.prompt_chars,
      "artifact" => artifact,
      "media_job" => redacted_job(job)
    }
    |> maybe_auto_send(artifact_path, artifact_name, Map.get(params, "sendToChannel") == true)
  end

  defp redacted_job(job) do
    job
    |> Map.take([
      :job_id,
      :type,
      :status,
      :provider,
      :model,
      :artifact,
      :prompt_hash,
      :prompt_chars,
      :created_at,
      :updated_at
    ])
    |> stringify_atoms()
  end

  defp stringify_atoms(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_atoms(value)} end)
  end

  defp stringify_atoms(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atoms(value), do: value

  defp maybe_auto_send(payload, _artifact_path, _artifact_name, false), do: payload

  defp maybe_auto_send(payload, artifact_path, artifact_name, true) do
    Map.put(payload, "auto_send_files", [
      %{
        "path" => artifact_path,
        "filename" => artifact_name,
        "caption" => "generated video preview",
        "source" => "generated"
      }
    ])
  end

  defp write_file(path, bytes) when is_binary(bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, bytes)
    end
  end

  defp artifact_bytes(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp video_id(video) when is_map(video) do
    optional_string(video["id"]) || optional_string(video[:id])
  end

  defp video_id(_video), do: nil

  defp video_status(video) when is_map(video) do
    video["status"] || video[:status]
  end

  defp video_status(_video), do: nil

  defp redacted_video_id(video) do
    case video_id(video) do
      id when is_binary(id) ->
        :crypto.hash(:sha256, id)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      _ ->
        nil
    end
  end

  defp operation_name(operation) when is_map(operation) do
    optional_string(operation["name"]) || optional_string(operation[:name])
  end

  defp operation_name(_operation), do: nil

  defp operation_done?(%{"done" => done}), do: done == true
  defp operation_done?(%{done: done}), do: done == true
  defp operation_done?(_operation), do: false

  defp operation_error(%{"error" => error}) when is_map(error), do: error
  defp operation_error(%{error: error}) when is_map(error), do: error
  defp operation_error(_operation), do: nil

  defp redacted_operation_name(operation) do
    case operation_name(operation) do
      name when is_binary(name) ->
        :crypto.hash(:sha256, name)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      _ ->
        nil
    end
  end

  defp decode_vertex_veo_response(operation, default_mime) do
    response = operation_response(operation)

    cond do
      is_binary(
        get_in(response, ["generatedVideos", Access.at(0), "video", "bytesBase64Encoded"])
      ) ->
        video = get_in(response, ["generatedVideos", Access.at(0), "video"])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      is_binary(get_in(response, [:generatedVideos, Access.at(0), :video, :bytesBase64Encoded])) ->
        video = get_in(response, [:generatedVideos, Access.at(0), :video])
        decode_vertex_veo_bytes(video[:bytesBase64Encoded], video[:mimeType], default_mime)

      is_binary(get_in(response, ["videos", Access.at(0), "bytesBase64Encoded"])) ->
        video = get_in(response, ["videos", Access.at(0)])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      is_binary(get_in(response, ["predictions", Access.at(0), "bytesBase64Encoded"])) ->
        video = get_in(response, ["predictions", Access.at(0)])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      has_vertex_veo_gcs_uri?(response) ->
        {:error, :vertex_veo_gcs_uri_response_unsupported}

      true ->
        {:error, :missing_vertex_veo_video}
    end
  end

  defp operation_response(%{"response" => response}) when is_map(response), do: response
  defp operation_response(%{response: response}) when is_map(response), do: response
  defp operation_response(response) when is_map(response), do: response
  defp operation_response(_operation), do: %{}

  defp decode_vertex_veo_bytes(encoded, mime_type, default_mime) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, {bytes, optional_string(mime_type) || default_mime}}
      :error -> {:error, :invalid_vertex_veo_base64}
    end
  end

  defp has_vertex_veo_gcs_uri?(%{"gcsUris" => [uri | _]}) when is_binary(uri), do: true

  defp has_vertex_veo_gcs_uri?(%{gcsUris: [uri | _]}) when is_binary(uri), do: true

  defp has_vertex_veo_gcs_uri?(%{"generatedVideos" => [%{"video" => %{"uri" => uri}} | _]})
       when is_binary(uri),
       do: true

  defp has_vertex_veo_gcs_uri?(%{generatedVideos: [%{video: %{uri: uri}} | _]})
       when is_binary(uri),
       do: true

  defp has_vertex_veo_gcs_uri?(_response), do: false

  defp vertex_aspect_ratio(value) do
    value
    |> optional_string()
    |> case do
      ratio when ratio in ["16:9", "9:16"] -> ratio
      "1280x720" -> "16:9"
      "720x1280" -> "9:16"
      _ -> nil
    end
  end

  defp vertex_duration(value) do
    value
    |> optional_string()
    |> case do
      nil -> nil
      value -> bounded_integer(value, 1, 60)
    end
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> bounded_integer(int, min, max)
      _ -> min
    end
  end

  defp bounded_integer(_value, min, _max), do: min

  defp reject_blank_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp provider_error_kind(%{"error" => error}) when is_map(error) do
    {:safe_error_kind,
     optional_string(error["type"]) || optional_string(error["status"]) ||
       optional_string(error["code"]) || "provider_error"}
  end

  defp provider_error_kind(%{error: error}) when is_map(error) do
    provider_error_kind(%{
      "error" => %{"type" => error[:type], "status" => error[:status], "code" => error[:code]}
    })
  end

  defp provider_error_kind(%{"detail" => detail}) when is_map(detail) do
    {:safe_error_kind,
     optional_string(detail["status"]) || optional_string(detail["type"]) ||
       optional_string(detail["code"]) || "provider_error"}
  end

  defp provider_error_kind(%{detail: detail}) when is_map(detail) do
    provider_error_kind(%{
      "detail" => %{"status" => detail[:status], "type" => detail[:type], "code" => detail[:code]}
    })
  end

  defp provider_error_kind(reason) when is_atom(reason),
    do: {:safe_error_kind, Atom.to_string(reason)}

  defp provider_error_kind(_reason), do: {:safe_error_kind, "provider_error"}

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".mp4" -> Map.fetch!(@formats, "mp4")
      _ -> "application/octet-stream"
    end
  end
end
