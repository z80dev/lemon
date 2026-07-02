defmodule LemonControlPlane.OpenAICompat do
  @moduledoc false

  alias LemonControlPlane.Methods.AgentWait
  alias LemonControlPlane.Methods.ModelsList
  alias AgentCore.ModelRuntime.ProviderNames
  alias LemonCore.RunRequest

  @default_agent_id "default"
  @default_queue_mode :collect
  @default_wait_timeout_ms 60_000
  @default_stream_timeout_ms 60_000
  @max_image_inputs 10
  @max_image_bytes 20_000_000

  def health do
    %{
      "object" => "lemon.health",
      "status" => "ok",
      "api" => "openai-compatible-preview"
    }
  end

  def capabilities do
    %{
      "object" => "lemon.capabilities",
      "status" => "preview",
      "endpoints" => %{
        "models" => true,
        "chat_completions" => true,
        "responses" => true,
        "runs" => true,
        "run_cancellation" => true,
        "streaming" => true,
        "image_input" => "data-url-pass-through",
        "image_url_fetch" => image_url_fetch_enabled?(),
        "image_url_fetch_policy" => image_url_fetch_policy(),
        "tool_progress" => true
      },
      "runtime" => %{
        "beam_supervised_runs" => true,
        "named_sessions" => true,
        "queued_runs" => true,
        "synchronous_wait" => true
      },
      "cleanup" => %{
        "includes_raw_api_keys" => false,
        "includes_provider_secrets" => false
      }
    }
  end

  def models do
    {:ok, %{"models" => models}} = ModelsList.handle(%{"discoverOpenAI" => false}, %{})

    %{
      "object" => "list",
      "data" => Enum.map(models, &model_object/1)
    }
  end

  def model(model_id) when is_binary(model_id) and model_id != "" do
    {:ok, %{"models" => models}} = ModelsList.handle(%{"discoverOpenAI" => false}, %{})

    models
    |> Enum.find(&(Map.get(&1, "id") == model_id))
    |> case do
      nil -> {:error, {404, "model not found"}}
      model -> {:ok, model_object(model)}
    end
  end

  def model(_model_id), do: {:error, {400, "model id is required"}}

  def chat_completion(params) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, messages} <- required_messages(params),
         {:ok, input} <- prompt_from_messages(messages),
         :ok <- validate_image_model_support(model, input),
         {:ok, result} <- submit(input, params, model, "chat.completions"),
         {:ok, result} <- maybe_wait(result, params) do
      {:ok, chat_completion_response(result, model)}
    end
  end

  def chat_completion(_params), do: {:error, {400, "request body must be a JSON object"}}

  def chat_completion_stream(params) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, messages} <- required_messages(params),
         {:ok, input} <- prompt_from_messages(messages),
         :ok <- validate_image_model_support(model, input),
         {:ok, result} <- submit(input, params, model, "chat.completions") do
      {:ok, stream_result(result, model, params)}
    end
  end

  def chat_completion_stream(_params), do: {:error, {400, "request body must be a JSON object"}}

  def response(params) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, input} <- prompt_from_input(Map.get(params, "input")),
         :ok <- validate_image_model_support(model, input),
         {:ok, previous_response} <- previous_response(params),
         {:ok, result} <- submit(input, params, model, "responses", previous_response),
         {:ok, result} <- maybe_wait(result, params) do
      {:ok, response_object(result, model)}
    end
  end

  def response(_params), do: {:error, {400, "request body must be a JSON object"}}

  def response_stream(params) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, input} <- prompt_from_input(Map.get(params, "input")),
         :ok <- validate_image_model_support(model, input),
         {:ok, previous_response} <- previous_response(params),
         {:ok, result} <- submit(input, params, model, "responses", previous_response) do
      {:ok, stream_result(result, model, params)}
    end
  end

  def response_stream(_params), do: {:error, {400, "request body must be a JSON object"}}

  def stream_requested?(params) when is_map(params), do: Map.get(params, "stream") == true
  def stream_requested?(_params), do: false

  def stored_response(response_id) when is_binary(response_id) and response_id != "" do
    with {:ok, run_id} <- run_id_from_response_id(response_id) do
      case run_getter().(run_id) do
        nil -> {:error, {404, "response not found"}}
        record when is_map(record) -> {:ok, stored_response_object(response_id, run_id, record)}
        _other -> {:error, {503, "failed to read Lemon response"}}
      end
    end
  end

  def stored_response(_response_id), do: {:error, {400, "response id is required"}}

  def run_status(run_id) when is_binary(run_id) and run_id != "" do
    case run_getter().(run_id) do
      nil -> {:error, {404, "run not found"}}
      record when is_map(record) -> {:ok, run_object(run_id, record)}
      _other -> {:error, {503, "failed to read Lemon run"}}
    end
  end

  def run_status(_run_id), do: {:error, {400, "run id is required"}}

  def cancel_run(run_id) when is_binary(run_id) and run_id != "" do
    with {:ok, run} <- run_status(run_id) do
      if terminal_run_status?(run["status"]) do
        {:ok, run}
      else
        canceller().(run_id, :openai_compat_cancel)
        {:ok, %{run | "status" => "cancelling"}}
      end
    end
  end

  def cancel_run(_run_id), do: {:error, {400, "run id is required"}}

  defp model_object(model) do
    id = model["id"]

    %{
      "id" => id,
      "object" => "model",
      "created" => nil,
      "owned_by" => model["provider"] || "lemon",
      "lemon" => %{
        "name" => model["name"] || id,
        "contextWindow" => model["contextWindow"],
        "maxOutput" => model["maxOutput"],
        "supportsThinking" => model["supportsThinking"],
        "supportsVision" => model["supportsVision"],
        "supportsStreaming" => model["supportsStreaming"]
      }
    }
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {400, "#{key} is required"}}
    end
  end

  defp required_messages(params) do
    case Map.get(params, "messages") do
      messages when is_list(messages) and messages != [] -> {:ok, messages}
      _ -> {:error, {400, "messages must be a non-empty array"}}
    end
  end

  defp prompt_from_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn
      %{"role" => role, "content" => content}, {:ok, acc} when is_binary(role) ->
        case content_payload(content) do
          {:ok, payload} -> {:cont, {:ok, [prefix_payload(role, payload) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _message, _acc ->
        {:halt, {:error, {400, "each message requires role and content"}}}
    end)
    |> case do
      {:ok, payloads} -> payloads |> Enum.reverse() |> join_payloads()
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_from_input(input) when is_binary(input) and input != "",
    do: {:ok, input_payload(input)}

  defp prompt_from_input(input) when is_list(input) do
    input
    |> Enum.map(&response_input_payload/1)
    |> join_input_payloads()
  end

  defp prompt_from_input(_input), do: {:error, {400, "input is required"}}

  defp response_input_payload(%{"role" => role, "content" => content}) when is_binary(role) do
    with {:ok, payload} <- content_payload(content) do
      {:ok, prefix_payload(role, payload)}
    end
  end

  defp response_input_payload(%{"type" => "message", "role" => role, "content" => content})
       when is_binary(role) do
    with {:ok, payload} <- content_payload(content) do
      {:ok, prefix_payload(role, payload)}
    end
  end

  defp response_input_payload(_item), do: {:error, {400, "unsupported input item"}}

  defp join_input_payloads(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, payload}, {:ok, acc} -> {:cont, {:ok, [payload | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, payloads} -> payloads |> Enum.reverse() |> join_payloads()
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_payload(content) when is_binary(content), do: {:ok, input_payload(content)}

  defp content_payload(content) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, [], [], [], 0, 0}, fn
      %{"type" => "text", "text" => text}, {:ok, texts, images, runtime_images, count, bytes}
      when is_binary(text) ->
        {:cont, {:ok, [text | texts], images, runtime_images, count, bytes}}

      %{"type" => "input_text", "text" => text},
      {:ok, texts, images, runtime_images, count, bytes}
      when is_binary(text) ->
        {:cont, {:ok, [text | texts], images, runtime_images, count, bytes}}

      part, {:ok, texts, images, runtime_images, count, bytes} ->
        case image_input(part) do
          {:ok, image, runtime_image, image_bytes} ->
            count = count + 1
            bytes = bytes + image_bytes

            cond do
              count > @max_image_inputs ->
                {:halt, {:error, {400, "too many image inputs"}}}

              bytes > @max_image_bytes ->
                {:halt, {:error, {413, "image inputs exceed size limit"}}}

              true ->
                runtime_images =
                  if runtime_image, do: [runtime_image | runtime_images], else: runtime_images

                {:cont, {:ok, texts, [image | images], runtime_images, count, bytes}}
            end

          :ignore ->
            {:cont, {:ok, texts, images, runtime_images, count, bytes}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, texts, images, runtime_images, _count, _bytes} ->
        texts = Enum.reverse(texts)
        images = Enum.reverse(images)
        runtime_images = Enum.reverse(runtime_images)

        case {texts, images} do
          {[], []} -> {:error, {400, "content must include text or image input"}}
          _ -> {:ok, input_payload(Enum.join(texts, "\n"), images, runtime_images)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_payload(_content), do: {:error, {400, "content must include text or image input"}}

  defp input_payload(text, image_inputs \\ [], runtime_images \\ []) do
    image_inputs =
      image_inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {image, index} -> with_image_prompt(image, index) end)

    image_prompt = image_inputs |> Enum.map(& &1.prompt) |> Enum.join("\n")

    prompt =
      [text, image_prompt]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n")

    %{
      prompt: prompt,
      image_inputs: Enum.map(image_inputs, &Map.delete(&1, :prompt)),
      images: runtime_images
    }
  end

  defp prefix_payload(role, payload) do
    prompt =
      case payload.prompt do
        "" -> role
        prompt -> "#{role}: #{prompt}"
      end

    %{payload | prompt: prompt}
  end

  defp join_payloads(payloads) do
    prompt =
      payloads
      |> Enum.map(& &1.prompt)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    image_inputs = Enum.flat_map(payloads, & &1.image_inputs)
    images = Enum.flat_map(payloads, &Map.get(&1, :images, []))
    {:ok, %{prompt: prompt, image_inputs: image_inputs, images: images}}
  end

  defp image_input(%{"type" => "image_url", "image_url" => %{"url" => url} = image})
       when is_binary(url) do
    image_reference(url, Map.get(image, "detail"))
  end

  defp image_input(%{"type" => "image_url", "image_url" => url}) when is_binary(url) do
    image_reference(url, nil)
  end

  defp image_input(%{"type" => "input_image", "image_url" => %{"url" => url} = image})
       when is_binary(url) do
    image_reference(url, Map.get(image, "detail"))
  end

  defp image_input(%{"type" => "input_image", "image_url" => url}) when is_binary(url) do
    image_reference(url, nil)
  end

  defp image_input(%{"type" => "input_image", "file_id" => file_id}) when is_binary(file_id) do
    {:ok,
     %{
       kind: "file_id",
       sha256: short_hash(file_id),
       detail: nil,
       mime_type: nil,
       redacted: true,
       pass_through: false
     }, nil, 0}
  end

  defp image_input(_part), do: :ignore

  defp image_reference(reference, detail) when is_binary(reference) do
    cond do
      String.starts_with?(reference, "data:") ->
        with {:ok, mime_type, data, byte_size} <- data_url_image(reference) do
          {:ok,
           %{
             kind: "data_url",
             sha256: short_hash(reference),
             detail: image_detail(detail),
             mime_type: mime_type,
             redacted: true,
             pass_through: true
           }, %{data: data, mime_type: mime_type}, byte_size}
        end

      String.starts_with?(reference, "http://") or String.starts_with?(reference, "https://") ->
        image_url_reference(reference, detail)

      true ->
        {:error, {400, "image_url must be an http(s) URL or data URL"}}
    end
  end

  defp image_url_reference(reference, detail) do
    if image_url_fetch_enabled?() do
      with :ok <- validate_image_url_fetch(reference),
           {:ok, mime_type, data, byte_size} <- fetch_image_url(reference) do
        {:ok,
         %{
           kind: "url",
           sha256: short_hash(reference),
           detail: image_detail(detail),
           mime_type: mime_type,
           redacted: true,
           pass_through: true,
           source: "remote_fetch"
         }, %{data: data, mime_type: mime_type}, byte_size}
      end
    else
      {:ok,
       %{
         kind: "url",
         sha256: short_hash(reference),
         detail: image_detail(detail),
         mime_type: nil,
         redacted: true,
         pass_through: false
       }, nil, 0}
    end
  end

  defp image_url_fetch_enabled? do
    truthy?(Application.get_env(:lemon_control_plane, :openai_compat_image_url_fetch)) ||
      truthy?(System.get_env("LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH"))
  end

  defp image_url_fetch_policy do
    if image_url_fetch_enabled?(), do: "https-allowlist", else: "metadata-only"
  end

  defp validate_image_url_fetch(reference) do
    case URI.parse(reference) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if image_url_host_allowed?(host) do
          :ok
        else
          {:error, {400, "image URL host is not allowed"}}
        end

      %URI{scheme: "http"} ->
        {:error, {400, "image URL fetch requires https"}}

      _other ->
        {:error, {400, "image_url must be an http(s) URL or data URL"}}
    end
  end

  defp image_url_host_allowed?(host) do
    allowed_hosts = image_url_allowed_hosts()
    normalized_host = String.downcase(host)
    normalized_host in allowed_hosts
  end

  defp image_url_allowed_hosts do
    configured =
      Application.get_env(:lemon_control_plane, :openai_compat_image_url_allowed_hosts) ||
        System.get_env("LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS") ||
        System.get_env("LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST")

    configured
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      value -> [value]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp fetch_image_url(reference) do
    fetcher =
      Application.get_env(
        :lemon_control_plane,
        :openai_compat_image_url_fetcher,
        &default_image_url_fetcher/2
      )

    case fetcher.(reference, max_bytes: @max_image_bytes) do
      {:ok, %{mime_type: mime_type, data: data, byte_size: byte_size}}
      when is_binary(mime_type) and is_binary(data) and is_integer(byte_size) ->
        if image_mime_type?(mime_type) do
          {:ok, mime_type, data, byte_size}
        else
          {:error, {400, "image URL MIME type is unsupported"}}
        end

      {:error, {status, message}} when is_integer(status) and is_binary(message) ->
        {:error, {status, message}}

      {:error, reason} ->
        {:error, {502, "failed to fetch image URL: #{inspect(reason)}"}}

      _other ->
        {:error, {502, "failed to fetch image URL"}}
    end
  end

  defp default_image_url_fetcher(reference, opts) do
    Application.ensure_all_started(:inets)
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    request = {String.to_charlist(reference), []}
    http_options = [timeout: 5_000, connect_timeout: 5_000]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_http_version, 200, _reason}, headers, body}} when is_binary(body) ->
        mime_type = response_mime_type(headers)
        byte_size = byte_size(body)

        cond do
          byte_size > max_bytes ->
            {:error, {413, "image URL response exceeds size limit"}}

          not image_mime_type?(mime_type) ->
            {:error, {400, "image URL MIME type is unsupported"}}

          true ->
            {:ok, %{mime_type: mime_type, data: Base.encode64(body), byte_size: byte_size}}
        end

      {:ok, {{_http_version, status, _reason}, _headers, _body}} ->
        {:error, {502, "image URL fetch returned HTTP #{status}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp response_mime_type(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if key |> to_string() |> String.downcase() == "content-type", do: to_string(value)
    end)
    |> case do
      nil ->
        nil

      content_type ->
        content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp with_image_prompt(image, index) do
    prompt =
      [
        "kind=#{image.kind}",
        "sha256=#{image.sha256}",
        image.detail && "detail=#{image.detail}",
        image.mime_type && "mime=#{image.mime_type}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Map.put(image, :prompt, "[image input #{index}: #{prompt}]")
  end

  defp image_detail(detail) when is_binary(detail) and detail in ["auto", "low", "high"],
    do: detail

  defp image_detail(_detail), do: nil

  defp data_url_image(reference) do
    case Regex.run(~r/^data:([^;,]+);base64,(.+)$/s, reference, capture: :all_but_first) do
      [mime_type, data] ->
        with true <- image_mime_type?(mime_type),
             {:ok, decoded} <- Base.decode64(data) do
          {:ok, mime_type, data, byte_size(decoded)}
        else
          false -> {:error, {400, "data URL image MIME type is unsupported"}}
          :error -> {:error, {400, "data URL image input must be valid base64"}}
        end

      _ ->
        {:error, {400, "data URL image input must be base64 encoded"}}
    end
  end

  defp image_mime_type?(mime_type) when is_binary(mime_type) do
    mime_type in ["image/png", "image/jpeg", "image/gif", "image/webp"]
  end

  defp image_mime_type?(_), do: false

  defp validate_image_model_support(model, input) do
    if runtime_image_input?(input) and model_image_support(model) == false do
      {:error, {400, "model does not support image input"}}
    else
      :ok
    end
  end

  defp runtime_image_input?(%{images: images}) when is_list(images), do: images != []
  defp runtime_image_input?(_input), do: false

  defp model_image_support(model) when is_binary(model) do
    with {:ok, provider, model_id} <- model_provider_and_id(model),
         provider_atom when is_atom(provider_atom) <- ProviderNames.provider_atom(provider),
         true <- Code.ensure_loaded?(Ai.Models),
         %{input: input} <- Ai.Models.get_model(provider_atom, model_id) do
      :image in input
    else
      _ -> :unknown
    end
  end

  defp model_image_support(_model), do: :unknown

  defp model_provider_and_id(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> {:ok, provider, model_id}
      _other -> {:error, :unprefixed_model}
    end
  end

  defp truthy?(value) when value in [true, "1", "true", "TRUE", "yes", "YES"], do: true
  defp truthy?(_value), do: false

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp submit(input, params, model, endpoint, previous_response \\ nil) do
    agent_id = string_param(params, "agent_id", @default_agent_id)
    default_session_key = previous_session_key(previous_response) || "agent:#{agent_id}:openai"
    session_key = string_param(params, "session_key", default_session_key)
    prompt = input.prompt
    image_inputs = input.image_inputs
    images = Map.get(input, :images, [])

    request =
      RunRequest.new(%{
        origin: :control_plane,
        session_key: session_key,
        agent_id: agent_id,
        prompt: prompt,
        images: images,
        queue_mode: queue_mode(params),
        model: model,
        cwd: Map.get(params, "cwd"),
        tool_policy: Map.get(params, "tool_policy"),
        meta: %{
          origin: :openai_compat,
          openai_endpoint: endpoint,
          streaming_requested: Map.get(params, "stream") == true,
          previous_response_id: previous_response_id(previous_response),
          openai_image_inputs: image_inputs,
          image_input_count: length(image_inputs)
        }
      })

    case submitter().(request) do
      {:ok, run_id} ->
        {:ok,
         %{
           run_id: run_id,
           session_key: session_key,
           prompt: prompt,
           endpoint: endpoint,
           status: "queued",
           previous_response_id: previous_response_id(previous_response),
           image_input_count: length(image_inputs)
         }}

      {:error, reason} ->
        {:error, {503, "failed to submit Lemon run: #{inspect(reason)}"}}
    end
  end

  defp maybe_wait(result, params) do
    if wait_requested?(params) do
      case waiter().(result.run_id, wait_timeout_ms(params)) do
        {:ok, wait_result} ->
          {:ok,
           result
           |> Map.put(:status, wait_status(wait_result))
           |> Map.put(:wait_result, wait_result)}

        {:error, {:timeout, message, _run_id}} ->
          {:error, {504, message}}

        {:error, :timeout} ->
          {:error, {504, "Run did not complete within timeout"}}

        {:error, reason} ->
          {:error, {503, "failed to wait for Lemon run: #{inspect(reason)}"}}
      end
    else
      {:ok, result}
    end
  end

  defp submitter do
    Application.get_env(:lemon_control_plane, :openai_compat_submitter, &LemonRouter.submit/1)
  end

  defp waiter do
    Application.get_env(:lemon_control_plane, :openai_compat_waiter, fn run_id, timeout_ms ->
      AgentWait.handle(%{"runId" => run_id, "timeoutMs" => timeout_ms}, %{})
    end)
  end

  defp run_getter do
    Application.get_env(
      :lemon_control_plane,
      :openai_compat_run_getter,
      &LemonCore.RunStore.get/1
    )
  end

  defp canceller do
    Application.get_env(:lemon_control_plane, :openai_compat_canceller, &LemonRouter.abort_run/2)
  end

  defp wait_requested?(params) do
    Map.get(params, "wait") == true || get_in(params, ["metadata", "wait"]) == true
  end

  defp wait_timeout_ms(params) do
    case Map.get(params, "timeout_ms") || Map.get(params, "timeoutMs") ||
           get_in(params, ["metadata", "timeout_ms"]) || get_in(params, ["metadata", "timeoutMs"]) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_wait_timeout_ms
    end
  end

  defp wait_status(%{"ok" => false}), do: "failed"
  defp wait_status(%{ok: false}), do: "failed"
  defp wait_status(_wait_result), do: "completed"

  defp stream_result(result, model, params) do
    result
    |> Map.put(:model, model)
    |> Map.put(:stream_timeout_ms, stream_timeout_ms(params))
  end

  defp stream_timeout_ms(params) do
    case Map.get(params, "stream_timeout_ms") || Map.get(params, "streamTimeoutMs") ||
           get_in(params, ["metadata", "stream_timeout_ms"]) ||
           get_in(params, ["metadata", "streamTimeoutMs"]) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_stream_timeout_ms
    end
  end

  defp string_param(params, key, default) do
    case Map.get(params, key) || get_in(params, ["metadata", key]) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp queue_mode(%{"queue_mode" => "followup"}), do: :followup
  defp queue_mode(%{"queue_mode" => "steer"}), do: :steer
  defp queue_mode(%{"queue_mode" => "interrupt"}), do: :interrupt
  defp queue_mode(_params), do: @default_queue_mode

  defp previous_response(params) do
    case Map.get(params, "previous_response_id") ||
           get_in(params, ["metadata", "previous_response_id"]) do
      nil ->
        {:ok, nil}

      response_id when is_binary(response_id) and response_id != "" ->
        with {:ok, run_id} <- run_id_from_response_id(response_id) do
          case run_getter().(run_id) do
            nil ->
              {:error, {404, "previous response not found"}}

            record when is_map(record) ->
              {:ok,
               %{
                 response_id: response_id,
                 run_id: run_id,
                 session_key: response_session_key(record)
               }}

            _other ->
              {:error, {503, "failed to read previous response"}}
          end
        end

      _other ->
        {:error, {400, "previous_response_id must be a string"}}
    end
  end

  defp run_id_from_response_id("resp_" <> run_id) when run_id != "", do: {:ok, run_id}
  defp run_id_from_response_id(_response_id), do: {:error, {400, "response id is invalid"}}

  defp previous_session_key(nil), do: nil
  defp previous_session_key(%{session_key: session_key}), do: session_key

  defp previous_response_id(nil), do: nil
  defp previous_response_id(%{response_id: response_id}), do: response_id

  defp chat_completion_response(result, model) do
    %{
      "id" => "chatcmpl_#{result.run_id}",
      "object" => "chat.completion",
      "created" => unix_now(),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => chat_finish_reason(result),
          "message" => %{
            "role" => "assistant",
            "content" => result_answer(result)
          }
        }
      ],
      "usage" => nil,
      "lemon" => queued_metadata(result)
    }
  end

  defp response_object(result, model) do
    %{
      "id" => "resp_#{result.run_id}",
      "object" => "response",
      "created_at" => unix_now(),
      "status" => result.status,
      "model" => model,
      "previous_response_id" => result.previous_response_id,
      "output" => response_output(result),
      "lemon" => queued_metadata(result)
    }
  end

  defp stored_response_object(response_id, run_id, record) do
    summary = map_get(record, :summary) || %{}
    completed = map_get(summary, :completed)

    %{
      "id" => response_id,
      "object" => "response",
      "created_at" => unix_from_ms(map_get(record, :started_at)),
      "status" => stored_response_status(record),
      "model" => stored_response_model(record),
      "output" => stored_response_output(completed),
      "error" => stored_response_error(completed),
      "lemon" => %{
        "runId" => run_id,
        "sessionKey" => response_session_key(record),
        "eventCount" => event_count(map_get(record, :events) || []),
        "ok" => completed_ok(completed)
      }
    }
  end

  defp chat_finish_reason(%{status: "completed"}), do: "stop"
  defp chat_finish_reason(%{status: "failed"}), do: "error"
  defp chat_finish_reason(_result), do: "queued"

  defp response_output(%{status: "queued"}), do: []

  defp response_output(result) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{
            "type" => "output_text",
            "text" => result_answer(result)
          }
        ]
      }
    ]
  end

  defp result_answer(%{wait_result: wait_result}) do
    case wait_result do
      %{"answer" => answer} when is_binary(answer) -> answer
      %{answer: answer} when is_binary(answer) -> answer
      _ -> ""
    end
  end

  defp result_answer(_result), do: ""

  defp stored_response_output(completed) do
    case map_get(completed, :answer) do
      answer when is_binary(answer) and answer != "" ->
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => answer}]
          }
        ]

      _other ->
        []
    end
  end

  defp stored_response_status(record) do
    case run_status_from_record(record) do
      "running" -> "in_progress"
      status -> status
    end
  end

  defp stored_response_model(record) do
    summary = map_get(record, :summary) || %{}
    map_get(summary, :model) || map_get(record, :model) || "lemon"
  end

  defp stored_response_error(nil), do: nil
  defp stored_response_error(completed), do: completed_error(completed)

  defp response_session_key(record) do
    summary = map_get(record, :summary) || %{}
    map_get(summary, :session_key)
  end

  defp queued_metadata(result) do
    %{
      "runId" => result.run_id,
      "sessionKey" => result.session_key,
      "previousResponseId" => result.previous_response_id,
      "imageInputCount" => Map.get(result, :image_input_count, 0),
      "status" => result.status,
      "events" => %{
        "jsonRpc" => "agent.wait",
        "webSocket" => "/ws"
      },
      "ok" => result_ok(result),
      "error" => result_error(result)
    }
  end

  defp result_ok(%{wait_result: %{"ok" => ok}}), do: ok
  defp result_ok(%{wait_result: %{ok: ok}}), do: ok
  defp result_ok(_result), do: nil

  defp result_error(%{wait_result: %{"error" => error}}), do: error
  defp result_error(%{wait_result: %{error: error}}), do: error
  defp result_error(_result), do: nil

  defp run_object(run_id, record) do
    summary = map_get(record, :summary) || %{}
    completed = map_get(summary, :completed)
    events = map_get(record, :events) || []

    %{
      "id" => run_id,
      "object" => "run",
      "status" => run_status_from_record(record),
      "created_at" => unix_from_ms(map_get(record, :started_at)),
      "completed_at" => unix_from_ms(completed_at_ms(summary)),
      "lemon" => %{
        "sessionKey" => map_get(summary, :session_key),
        "eventCount" => event_count(events),
        "ok" => completed_ok(completed),
        "error" => completed_error(completed)
      }
    }
  end

  defp run_status_from_record(record) do
    summary = map_get(record, :summary)
    completed = map_get(summary || %{}, :completed)

    cond do
      is_nil(summary) -> "running"
      completed_ok(completed) == true -> "completed"
      completed_ok(completed) == false -> "failed"
      true -> "completed"
    end
  end

  defp terminal_run_status?(status), do: status in ["completed", "failed", "cancelled"]

  defp completed_ok(nil), do: nil
  defp completed_ok(completed), do: map_get(completed, :ok)

  defp completed_error(nil), do: nil

  defp completed_error(completed) do
    case map_get(completed, :error) do
      nil -> nil
      error when is_binary(error) -> error
      error -> inspect(error)
    end
  end

  defp completed_at_ms(summary) do
    map_get(summary, :completed_at_ms) || map_get(summary, :completed_at) ||
      map_get(summary, :finished_at_ms)
  end

  defp event_count(events) when is_list(events), do: length(events)
  defp event_count(_events), do: nil

  defp unix_from_ms(ms) when is_integer(ms), do: div(ms, 1000)
  defp unix_from_ms(_ms), do: nil

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp unix_now, do: System.system_time(:second)
end
