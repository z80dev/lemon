defmodule LemonControlPlane.OpenAICompat do
  @moduledoc false

  # Every run/session entry point takes the caller's auth context (see
  # `LemonControlPlane.Auth.Authorize.authenticate_api/3`). A principal without
  # `:admin` (the `LEMON_OPENAI_COMPAT_API_TOKEN` principal) only sees runs it
  # submitted, runs inside `agent:<agent>:openai:api[:<label>]` session keys and
  # the API workspace, and cannot relax approvals through `tool_policy`.

  alias LemonControlPlane.APIWorkspace
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.AgentWait
  alias LemonControlPlane.Methods.ModelsList
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCore.RunRequest
  alias LemonCore.ToolPolicy

  @default_agent_id "default"
  @default_queue_mode :collect
  @default_wait_timeout_ms 60_000
  @default_stream_timeout_ms 60_000
  @max_image_inputs 10
  @max_image_bytes 20_000_000
  # Owner rows expire (LemonCore.Store sweeps `:expires_at`) after the same
  # window the store keeps introspection history; afterwards only admin can
  # address the run.
  @run_owner_table :openai_compat_run_owners
  @run_owner_ttl_ms 7 * 24 * 60 * 60 * 1000
  @api_label ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

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

  def chat_completion(params, auth) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, messages} <- required_messages(params),
         {:ok, input} <- prompt_from_messages(messages),
         :ok <- validate_image_model_support(model, input),
         {:ok, result} <- submit(input, params, model, "chat.completions", auth),
         {:ok, result} <- maybe_wait(result, params) do
      {:ok, chat_completion_response(result, model)}
    end
  end

  def chat_completion(_params, _auth),
    do: {:error, {400, "request body must be a JSON object"}}

  def chat_completion_stream(params, auth) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, messages} <- required_messages(params),
         {:ok, input} <- prompt_from_messages(messages),
         :ok <- validate_image_model_support(model, input),
         {:ok, result} <- submit(input, params, model, "chat.completions", auth) do
      {:ok, stream_result(result, model, params)}
    end
  end

  def chat_completion_stream(_params, _auth),
    do: {:error, {400, "request body must be a JSON object"}}

  def response(params, auth) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, input} <- prompt_from_input(Map.get(params, "input")),
         :ok <- validate_image_model_support(model, input),
         {:ok, previous_response} <- previous_response(params, auth),
         {:ok, result} <- submit(input, params, model, "responses", auth, previous_response),
         {:ok, result} <- maybe_wait(result, params) do
      {:ok, response_object(result, model)}
    end
  end

  def response(_params, _auth), do: {:error, {400, "request body must be a JSON object"}}

  def response_stream(params, auth) when is_map(params) do
    with {:ok, model} <- required_string(params, "model"),
         {:ok, input} <- prompt_from_input(Map.get(params, "input")),
         :ok <- validate_image_model_support(model, input),
         {:ok, previous_response} <- previous_response(params, auth),
         {:ok, result} <- submit(input, params, model, "responses", auth, previous_response) do
      {:ok, stream_result(result, model, params)}
    end
  end

  def response_stream(_params, _auth), do: {:error, {400, "request body must be a JSON object"}}

  def stream_requested?(params) when is_map(params), do: Map.get(params, "stream") == true
  def stream_requested?(_params), do: false

  def stored_response(response_id, auth) when is_binary(response_id) and response_id != "" do
    with {:ok, run_id} <- run_id_from_response_id(response_id),
         {:ok, record} <-
           fetch_run(run_id, auth, "response not found", "failed to read Lemon response") do
      {:ok, stored_response_object(response_id, run_id, record)}
    end
  end

  def stored_response(_response_id, _auth), do: {:error, {400, "response id is required"}}

  def run_status(run_id, auth) when is_binary(run_id) and run_id != "" do
    with {:ok, record} <- fetch_run(run_id, auth, "run not found", "failed to read Lemon run") do
      {:ok, run_object(run_id, record)}
    end
  end

  def run_status(_run_id, _auth), do: {:error, {400, "run id is required"}}

  def cancel_run(run_id, auth) when is_binary(run_id) and run_id != "" do
    with {:ok, run} <- run_status(run_id, auth) do
      if terminal_run_status?(run["status"]) do
        {:ok, run}
      else
        case canceller().(run_id, :openai_compat_cancel) do
          :ok -> {:ok, %{run | "status" => "cancelling"}}
          {:ok, _} -> {:ok, %{run | "status" => "cancelling"}}
          other -> {:error, {503, "failed to cancel Lemon run: #{inspect(other)}"}}
        end
      end
    end
  end

  def cancel_run(_run_id, _auth), do: {:error, {400, "run id is required"}}

  # Admin principals (the operator) may address any run; every other principal
  # only the runs recorded as its own at submit time. Unowned runs read as
  # missing so run ids cannot be probed.
  defp fetch_run(run_id, auth, missing, unreadable) do
    if admin?(auth) or run_owner?(run_id, auth) do
      case run_getter().(run_id) do
        nil -> {:error, {404, missing}}
        record when is_map(record) -> {:ok, record}
        _other -> {:error, {503, unreadable}}
      end
    else
      {:error, {404, missing}}
    end
  end

  # The store sweeps expired rows periodically; an expired row is refused here
  # too so ownership never outlives its TTL between sweeps.
  defp run_owner?(run_id, auth) do
    principal = Authorize.principal_id(auth)

    case LemonCore.Store.get(@run_owner_table, run_id) do
      %{principal: ^principal, expires_at: expires_at} when is_integer(expires_at) ->
        expires_at > System.system_time(:millisecond)

      _ ->
        false
    end
  end

  defp admin?(%{scopes: scopes}), do: :admin in scopes

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

  @image_url_fetch_timeout_ms 5_000

  # Pinned fetch via the shared address policy: public destinations only, no
  # redirects (any 3xx fails). Status and content-type are checked from the
  # headers before any body is read; the body is then pulled under the size cap
  # and one overall deadline. The `:openai_compat_image_url_http_options` env is
  # an internal test seam passing `:resolver`/`:allow_private`/`:ssl` through to
  # `LemonCore.Net.HTTP` so tests can use a loopback TLS listener.
  defp default_image_url_fetcher(reference, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    deadline = System.monotonic_time(:millisecond) + @image_url_fetch_timeout_ms

    test_opts =
      :lemon_control_plane
      |> Application.get_env(:openai_compat_image_url_http_options, [])
      |> Keyword.take([:resolver, :allow_private, :ssl])

    case LemonCore.Net.HTTP.open_stream(
           :get,
           reference,
           [timeout_ms: @image_url_fetch_timeout_ms] ++ test_opts
         ) do
      {:ok, stream} ->
        try do
          mime_type = response_mime_type(stream.headers)

          cond do
            stream.status != 200 ->
              {:error, {502, "image URL fetch returned HTTP #{stream.status}"}}

            not image_mime_type?(mime_type) ->
              {:error, {400, "image URL MIME type is unsupported"}}

            true ->
              with {:ok, body} <- read_image_body(stream, [], 0, max_bytes, deadline) do
                {:ok,
                 %{mime_type: mime_type, data: Base.encode64(body), byte_size: byte_size(body)}}
              end
          end
        after
          LemonCore.Net.HTTP.close_stream(stream)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_image_body(stream, acc, size, max_bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case LemonCore.Net.HTTP.stream_next(stream, remaining) do
        {status, stream, chunks} when status in [:ok, :done] ->
          size = size + IO.iodata_length(chunks)
          acc = [acc | chunks]

          cond do
            size > max_bytes -> {:error, {413, "image URL response exceeds size limit"}}
            status == :done -> {:ok, IO.iodata_to_binary(acc)}
            true -> read_image_body(stream, acc, size, max_bytes, deadline)
          end

        {:error, reason} ->
          {:error, reason}
      end
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
         true <- Code.ensure_loaded?(LemonAi.Models),
         %{input: input} <- LemonAi.Models.get_model(provider_atom, model_id) do
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

  defp submit(input, params, model, endpoint, auth, previous_response \\ nil) do
    with {:ok, agent_id} <- request_agent_id(params, auth),
         {:ok, session_key} <- request_session_key(params, agent_id, previous_response, auth),
         {:ok, cwd} <- request_cwd(params, auth),
         {:ok, tool_policy} <- request_tool_policy(params, auth) do
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
          cwd: cwd,
          tool_policy: tool_policy,
          meta: %{
            origin: :openai_compat,
            openai_endpoint: endpoint,
            streaming_requested: Map.get(params, "stream") == true,
            previous_response_id: previous_response_id(previous_response),
            openai_image_inputs: image_inputs,
            image_input_count: length(image_inputs)
          }
        })

      with {:ok, run_id} <- submit_owned(request, auth) do
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
      end
    end
  end

  # The owner record is what lets a non-admin principal read or cancel the run
  # later; a run whose owner cannot be recorded is cancelled, not orphaned.
  defp submit_owned(request, auth) do
    case submitter().(request) do
      {:ok, run_id} ->
        owner = %{
          principal: Authorize.principal_id(auth),
          expires_at: System.system_time(:millisecond) + @run_owner_ttl_ms
        }

        case LemonCore.Store.put(LemonCore.Store, @run_owner_table, run_id, owner, durable: true) do
          :ok ->
            {:ok, run_id}

          {:error, reason} ->
            canceller().(run_id, :openai_compat_owner_unrecorded)
            {:error, {503, "failed to record Lemon run owner: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        {:error, {503, "failed to submit Lemon run: #{inspect(reason)}"}}
    end
  end

  defp request_agent_id(params, auth) do
    agent_id = string_param(params, "agent_id", @default_agent_id)

    if admin?(auth) or Regex.match?(@api_label, agent_id),
      do: {:ok, agent_id},
      else: {:error, {400, "agent_id must contain only letters, digits, '.', '_' or '-'"}}
  end

  # Admin keeps free choice of session key. Other principals are confined to
  # `agent:<agent>:openai:api`; a caller key is a label inside that namespace
  # (the full namespaced key returned in `lemon.sessionKey` is accepted too).
  defp request_session_key(params, agent_id, previous_response, auth) do
    requested =
      string_param(params, "session_key", nil) || previous_session_key(previous_response)

    if admin?(auth) do
      {:ok, requested || "agent:#{agent_id}:openai"}
    else
      namespace = "agent:#{agent_id}:openai:api"

      case requested do
        nil ->
          {:ok, namespace}

        ^namespace ->
          {:ok, namespace}

        key ->
          label = String.replace_prefix(key, namespace <> ":", "")

          if Regex.match?(@api_label, label),
            do: {:ok, namespace <> ":" <> label},
            else:
              {:error,
               {400,
                "session_key must be a label of letters, digits, '.', '_' or '-' inside #{namespace}"}}
      end
    end
  end

  # Non-admin principals run in the API workspace; a caller cwd must resolve,
  # symlinks included, inside it (`LemonControlPlane.APIWorkspace`).
  defp request_cwd(params, auth) do
    cwd = Map.get(params, "cwd")

    result =
      cond do
        admin?(auth) -> {:ok, cwd}
        is_nil(cwd) -> APIWorkspace.root()
        true -> APIWorkspace.confine(cwd)
      end

    case result do
      {:ok, cwd} -> {:ok, cwd}
      {:error, :outside} -> {:error, {400, "cwd must be a directory inside the API workspace"}}
      {:error, :unavailable} -> {:error, {503, "API workspace is unavailable"}}
    end
  end

  defp request_tool_policy(params, auth) do
    case Map.get(params, "tool_policy") do
      nil ->
        {:ok, nil}

      policy ->
        case ToolPolicy.parse(policy) do
          {:ok, parsed} ->
            if :approvals in auth.scopes or not relaxes_approvals?(parsed),
              do: {:ok, parsed},
              else:
                {:error,
                 {400, "tool_policy cannot relax approvals without the operator approvals scope"}}

          {:error, reason} ->
            {:error, {400, "tool_policy is invalid: #{inspect(reason)}"}}
        end
    end
  end

  defp relaxes_approvals?(%ToolPolicy{approval_mode: mode, approvals: approvals}) do
    mode not in [nil, :ask] or Enum.any?(approvals, fn {_tool, gate} -> gate != :always end)
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

  # The API token authorized this caller to submit the run, so it receives the
  # run's answer (content) back.
  defp waiter do
    Application.get_env(:lemon_control_plane, :openai_compat_waiter, fn run_id, timeout_ms ->
      AgentWait.handle(
        %{"runId" => run_id, "timeoutMs" => timeout_ms},
        %{auth: %{role: :operator, scopes: [:read, :content]}}
      )
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

  defp previous_response(params, auth) do
    case Map.get(params, "previous_response_id") ||
           get_in(params, ["metadata", "previous_response_id"]) do
      nil ->
        {:ok, nil}

      response_id when is_binary(response_id) and response_id != "" ->
        with {:ok, run_id} <- run_id_from_response_id(response_id),
             {:ok, record} <-
               fetch_run(
                 run_id,
                 auth,
                 "previous response not found",
                 "failed to read previous response"
               ) do
          {:ok,
           %{
             response_id: response_id,
             run_id: run_id,
             session_key: response_session_key(record)
           }}
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
