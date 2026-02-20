defmodule LemonGateway.Transports.Webhook do
  @moduledoc false

  use Plug.Router
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Runtime
  alias LemonGateway.Types.Job
  alias LemonCore.{Id, SessionKey}

  @default_timeout_ms 30_000
  @default_port if(Code.ensure_loaded?(Mix) and Mix.env() == :test, do: 0, else: 4046)

  plug(Plug.Logger, log: :debug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  @impl LemonGateway.Transport
  def id, do: "webhook"

  @impl LemonGateway.Transport
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @impl LemonGateway.Transport
  def start_link(_opts) do
    if enabled?() do
      cfg = config()
      ip = bind_ip(cfg)
      port = int_value(fetch(cfg, :port), @default_port)

      Logger.info("Starting webhook transport server on #{inspect(ip)}:#{port}")

      Bandit.start_link(
        plug: __MODULE__,
        ip: ip,
        port: port,
        scheme: :http
      )
    else
      Logger.info("webhook transport disabled")
      :ignore
    end
  end

  post "/webhooks/:integration_id" do
    payload = Map.drop(conn.params || %{}, ["integration_id"])

    with %{} = integration <- integration_config(integration_id),
         :ok <- authorize_request(conn, payload, integration),
         {:ok, normalized} <- normalize_payload(payload),
         {:ok, run_ctx} <- submit_run(conn, integration_id, integration, payload, normalized),
         {:ok, status, response_payload} <- response_for_run(run_ctx) do
      json(conn, status, response_payload)
    else
      nil ->
        json_error(conn, 404, "integration not found")

      {:error, :unauthorized} ->
        json_error(conn, 401, "unauthorized")

      {:error, :unprocessable_entity} ->
        json_error(conn, 422, "invalid request payload")

      {:error, :run_timeout} ->
        json_error(conn, 500, "run timed out")

      {:error, reason} ->
        Logger.warning("webhook transport request failed: #{inspect(reason)}")
        json_error(conn, 500, "internal server error")
    end
  end

  match _ do
    json_error(conn, 404, "not found")
  end

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_webhook) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})
      fallback = Application.get_env(:lemon_gateway, :enable_webhook, false)

      cond do
        is_list(cfg) -> Keyword.get(cfg, :enable_webhook, fallback)
        is_map(cfg) -> fetch(cfg, :enable_webhook) || fallback
        true -> fallback
      end == true
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:webhook) || %{}
      else
        override = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

        from_override =
          cond do
            is_list(override) and Keyword.keyword?(override) -> Keyword.get(override, :webhook)
            is_map(override) -> fetch(override, :webhook)
            true -> nil
          end

        from_override || Application.get_env(:lemon_gateway, :webhook, %{})
      end

    normalize_map(cfg)
  rescue
    _ -> %{}
  end

  @doc false
  def normalize_payload_for_test(payload), do: normalize_payload(payload)

  @doc false
  def secure_compare_for_test(expected, provided), do: secure_compare(expected, provided)

  @doc false
  def wait_for_run_completion_for_test(run_id, timeout_ms) do
    wait_for_run_completion(run_id, timeout_ms)
  end

  defp response_for_run(%{mode: :sync} = run_ctx) do
    case wait_for_run_completion(run_ctx.run_id, run_ctx.timeout_ms) do
      {:ok, run_payload} ->
        callback =
          maybe_send_callback(
            run_ctx.callback_url,
            callback_payload(run_ctx, run_payload),
            run_ctx.timeout_ms
          )

        payload =
          %{
            run_id: run_ctx.run_id,
            session_key: run_ctx.session_key,
            mode: "sync",
            completed: completed_payload(run_payload),
            duration_ms: fetch(run_payload, :duration_ms)
          }
          |> maybe_put(:callback, callback)

        {:ok, 200, payload}

      {:error, :timeout} ->
        {:error, :run_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp response_for_run(run_ctx) do
    callback_status = maybe_schedule_callback(run_ctx)

    payload =
      %{
        run_id: run_ctx.run_id,
        session_key: run_ctx.session_key,
        mode: "async",
        status: "accepted"
      }
      |> maybe_put(:callback, callback_status)

    {:ok, 202, payload}
  end

  defp submit_run(conn, integration_id, integration, payload, normalized) do
    run_id = Id.run_id()
    session_key = resolve_session_key(integration)
    mode = resolve_mode(integration)
    timeout_ms = resolve_timeout_ms(integration)
    callback_url = resolve_callback_url(payload, integration)
    queue_mode = resolve_queue_mode(integration)

    job = %Job{
      run_id: run_id,
      session_key: session_key,
      prompt: normalized.prompt,
      engine_id: resolve_engine(integration),
      cwd: normalize_blank(fetch(integration, :cwd)),
      queue_mode: queue_mode,
      meta: %{
        origin: :webhook,
        webhook: %{
          integration_id: integration_id,
          metadata: normalized.metadata,
          attachments: normalized.attachments,
          request: request_metadata(conn),
          integration: integration_metadata(integration)
        }
      }
    }

    :ok = Runtime.submit(job)

    {:ok,
     %{
       integration_id: integration_id,
       run_id: run_id,
       session_key: session_key,
       mode: mode,
       timeout_ms: timeout_ms,
       callback_url: callback_url,
       metadata: normalized.metadata,
       attachments: normalized.attachments
     }}
  rescue
    error ->
      {:error, {:submit_failed, Exception.message(error)}}
  end

  defp integration_metadata(integration) do
    %{
      session_key: fetch(integration, :session_key),
      agent_id: fetch(integration, :agent_id),
      queue_mode: resolve_queue_mode(integration),
      default_engine: resolve_engine(integration),
      cwd: normalize_blank(fetch(integration, :cwd)),
      callback_url_configured: is_binary(normalize_blank(fetch(integration, :callback_url))),
      mode: resolve_mode(integration),
      timeout_ms: resolve_timeout_ms(integration)
    }
  end

  defp authorize_request(conn, payload, integration) do
    expected = normalize_blank(fetch(integration, :token))

    provided =
      first_non_blank([
        authorization_token(conn),
        List.first(Plug.Conn.get_req_header(conn, "x-webhook-token")),
        fetch_any(payload, [["token"]])
      ])

    if secure_compare(expected, provided) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorization_token(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> normalize_blank()
    |> case do
      nil ->
        nil

      "Bearer " <> token ->
        normalize_blank(token)

      "bearer " <> token ->
        normalize_blank(token)

      token ->
        normalize_blank(token)
    end
  end

  defp secure_compare(expected, provided)
       when is_binary(expected) and is_binary(provided) and
              byte_size(expected) == byte_size(provided) do
    Plug.Crypto.secure_compare(expected, provided)
  rescue
    _ -> false
  end

  defp secure_compare(_, _), do: false

  defp normalize_payload(payload) when is_map(payload) do
    prompt_text = extract_prompt(payload)
    attachments = extract_attachments(payload)
    metadata = extract_metadata(payload)
    prompt = build_prompt(prompt_text, attachments)

    if is_binary(prompt) and String.trim(prompt) != "" do
      {:ok,
       %{
         prompt: prompt,
         prompt_text: prompt_text,
         attachments: attachments,
         metadata: metadata
       }}
    else
      {:error, :unprocessable_entity}
    end
  end

  defp normalize_payload(_), do: {:error, :unprocessable_entity}

  defp extract_prompt(payload) do
    first_non_blank([
      fetch_any(payload, [["prompt"]]),
      fetch_any(payload, [["text"]]),
      fetch_any(payload, [["message"]]),
      fetch_any(payload, [["input"]]),
      fetch_any(payload, [["body", "text"]]),
      fetch_any(payload, [["body.text"]]),
      fetch_any(payload, [["content", "text"]]),
      fetch_any(payload, [["content.text"]])
    ])
  end

  defp extract_metadata(payload) do
    case fetch_any(payload, [["metadata"]]) do
      value when is_map(value) ->
        value

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp extract_attachments(payload) do
    [
      {"attachments", fetch_any(payload, [["attachments"]])},
      {"files", fetch_any(payload, [["files"]])},
      {"urls", fetch_any(payload, [["urls"]])}
    ]
    |> Enum.flat_map(fn {source, value} -> normalize_attachment_input(value, source) end)
    |> Enum.reject(&attachment_empty?/1)
    |> Enum.uniq_by(fn attachment ->
      {attachment[:source], attachment[:url], attachment[:name], attachment[:content_type],
       attachment[:size]}
    end)
  end

  defp normalize_attachment_input(nil, _source), do: []

  defp normalize_attachment_input(value, source) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        normalize_attachment_input(decoded, source)

      _ ->
        [%{source: source, url: value}]
    end
  end

  defp normalize_attachment_input(value, source) when is_list(value) do
    Enum.flat_map(value, &normalize_attachment_input(&1, source))
  end

  defp normalize_attachment_input(value, source) when is_map(value) do
    normalized =
      %{
        source: source,
        url: first_non_blank([fetch(value, :url), fetch(value, :href), fetch(value, :uri)]),
        name:
          first_non_blank([
            fetch(value, :name),
            fetch(value, :filename),
            fetch(value, :file_name),
            fetch(value, :title)
          ]),
        content_type:
          first_non_blank([
            fetch(value, :content_type),
            fetch(value, :mime_type),
            fetch(value, :type)
          ]),
        size: int_value(first_non_blank([fetch(value, :size), fetch(value, :bytes)]), nil)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(normalized) > 1 do
      [normalized]
    else
      value
      |> Map.values()
      |> Enum.flat_map(&normalize_attachment_input(&1, source))
    end
  end

  defp normalize_attachment_input(_value, _source), do: []

  defp attachment_empty?(attachment) do
    attachment
    |> Map.drop([:source])
    |> map_size()
    |> Kernel.==(0)
  end

  defp build_prompt(prompt_text, []), do: prompt_text

  defp build_prompt(prompt_text, attachments) do
    attachment_lines =
      attachments
      |> Enum.map(&attachment_line/1)
      |> Enum.reject(&is_nil/1)

    context =
      case attachment_lines do
        [] -> nil
        lines -> "Attachments:\n" <> Enum.join(lines, "\n")
      end

    [prompt_text, context]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> normalize_blank()
  end

  defp attachment_line(attachment) when is_map(attachment) do
    url = normalize_blank(fetch(attachment, :url))
    name = normalize_blank(fetch(attachment, :name))

    cond do
      is_binary(name) and is_binary(url) -> "- #{name} (#{url})"
      is_binary(url) -> "- #{url}"
      is_binary(name) -> "- #{name}"
      true -> nil
    end
  end

  defp attachment_line(_), do: nil

  defp resolve_session_key(integration) do
    case normalize_blank(fetch(integration, :session_key)) do
      session_key when is_binary(session_key) ->
        session_key

      _ ->
        agent_id = normalize_blank(fetch(integration, :agent_id)) || "default"
        SessionKey.main(agent_id)
    end
  end

  defp resolve_engine(integration) do
    normalize_blank(fetch(integration, :default_engine)) || default_engine()
  end

  defp resolve_queue_mode(integration) do
    case fetch(integration, :queue_mode) do
      mode when mode in [:collect, :followup, :steer, :steer_backlog, :interrupt] ->
        mode

      "collect" ->
        :collect

      "followup" ->
        :followup

      "steer" ->
        :steer

      "steer_backlog" ->
        :steer_backlog

      "interrupt" ->
        :interrupt

      _ ->
        :collect
    end
  end

  defp resolve_mode(integration) do
    case parse_mode(fetch(integration, :mode)) || parse_mode(fetch(config(), :mode)) do
      :sync -> :sync
      _ -> :async
    end
  end

  defp parse_mode(nil), do: nil
  defp parse_mode(:sync), do: :sync
  defp parse_mode(:async), do: :async
  defp parse_mode("sync"), do: :sync
  defp parse_mode("async"), do: :async
  defp parse_mode(_), do: nil

  defp resolve_timeout_ms(integration) do
    integration_timeout = int_value(fetch(integration, :timeout_ms), nil)
    webhook_timeout = int_value(fetch(config(), :timeout_ms), nil)

    integration_timeout || webhook_timeout || @default_timeout_ms
  end

  defp resolve_callback_url(payload, integration) do
    first_non_blank([
      fetch_any(payload, [["callback_url"]]),
      fetch_any(payload, [["callbackUrl"]]),
      fetch_any(payload, [["callback", "url"]]),
      fetch(integration, :callback_url),
      fetch(config(), :callback_url)
    ])
  end

  defp maybe_schedule_callback(%{callback_url: callback_url} = run_ctx) do
    if is_binary(callback_url) and callback_url != "" do
      Task.start(fn ->
        case wait_for_run_completion(run_ctx.run_id, run_ctx.timeout_ms) do
          {:ok, run_payload} ->
            case send_callback(
                   callback_url,
                   callback_payload(run_ctx, run_payload),
                   run_ctx.timeout_ms
                 ) do
              {:ok, _status} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "webhook callback delivery failed run_id=#{run_ctx.run_id}: #{inspect(reason)}"
                )
            end

          {:error, :timeout} ->
            Logger.warning("webhook callback wait timed out for run_id=#{run_ctx.run_id}")

          {:error, reason} ->
            Logger.warning(
              "webhook callback wait failed for run_id=#{run_ctx.run_id}: #{inspect(reason)}"
            )
        end
      end)

      %{status: "scheduled", url: callback_url}
    else
      nil
    end
  end

  defp maybe_send_callback(nil, _payload, _timeout_ms), do: nil
  defp maybe_send_callback("", _payload, _timeout_ms), do: nil

  defp maybe_send_callback(callback_url, payload, timeout_ms) do
    case send_callback(callback_url, payload, timeout_ms) do
      {:ok, status} ->
        %{status: "sent", http_status: status}

      {:error, reason} ->
        %{status: "failed", error: inspect(reason)}
    end
  end

  defp send_callback(callback_url, payload, timeout_ms) when is_binary(callback_url) do
    request_timeout = int_value(timeout_ms, @default_timeout_ms)
    body = Jason.encode!(payload)

    request =
      {String.to_charlist(callback_url), [{~c"content-type", ~c"application/json"}],
       ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: request_timeout, connect_timeout: min(request_timeout, 5_000)],
           []
         ) do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, _resp_body}} ->
        {:ok, status}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:callback_failed, Exception.message(error)}}
  end

  defp send_callback(_callback_url, _payload, _timeout_ms), do: {:error, :invalid_callback_url}

  defp callback_payload(run_ctx, run_payload) do
    %{
      integration_id: run_ctx.integration_id,
      run_id: run_ctx.run_id,
      session_key: run_ctx.session_key,
      completed: completed_payload(run_payload),
      duration_ms: fetch(run_payload, :duration_ms),
      metadata: run_ctx.metadata,
      attachments: run_ctx.attachments
    }
  end

  defp completed_payload(payload) do
    fetch(payload, :completed) || payload
  end

  defp request_metadata(conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      remote_ip: remote_ip_to_string(conn.remote_ip),
      user_agent: List.first(Plug.Conn.get_req_header(conn, "user-agent")),
      request_id: List.first(Plug.Conn.get_req_header(conn, "x-request-id"))
    }
  end

  defp remote_ip_to_string({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp remote_ip_to_string({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp remote_ip_to_string(_), do: nil

  defp wait_for_run_completion(run_id, timeout_ms) when is_binary(run_id) do
    topic = LemonCore.Bus.run_topic(run_id)
    timeout_ms = int_value(timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    :ok = LemonCore.Bus.subscribe(topic)

    try do
      wait_for_run_completion_loop(deadline)
    after
      _ = LemonCore.Bus.unsubscribe(topic)
    end
  rescue
    error ->
      {:error, {:wait_failed, Exception.message(error)}}
  end

  defp wait_for_run_completion(_run_id, _timeout_ms), do: {:error, :invalid_run_id}

  defp wait_for_run_completion_loop(deadline_ms) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline_ms - now

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        message ->
          case extract_run_completed(message) do
            {:ok, payload} -> {:ok, payload}
            :skip -> wait_for_run_completion_loop(deadline_ms)
          end
      after
        remaining ->
          {:error, :timeout}
      end
    end
  end

  defp extract_run_completed(%LemonCore.Event{type: :run_completed, payload: payload}),
    do: {:ok, payload}

  defp extract_run_completed(%{type: :run_completed, payload: payload}), do: {:ok, payload}
  defp extract_run_completed({:run_completed, payload}), do: {:ok, payload}
  defp extract_run_completed(_), do: :skip

  defp integration_config(integration_id) when is_binary(integration_id) do
    integrations = fetch(config(), :integrations)

    if is_map(integrations) do
      Enum.find_value(integrations, fn {key, value} ->
        if to_string(key) == integration_id do
          normalize_map(value)
        end
      end)
    else
      nil
    end
  end

  defp integration_config(_), do: nil

  defp bind_ip(cfg) do
    case normalize_blank(fetch(cfg, :bind)) do
      nil -> :loopback
      "127.0.0.1" -> :loopback
      "localhost" -> :loopback
      "0.0.0.0" -> :any
      "any" -> :any
      other -> parse_ip(other) || :loopback
    end
  end

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

  defp default_engine do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:default_engine) || "lemon"
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      cond do
        is_list(cfg) -> Keyword.get(cfg, :default_engine, "lemon")
        is_map(cfg) -> fetch(cfg, :default_engine) || "lemon"
        true -> "lemon"
      end
    end
  rescue
    _ -> "lemon"
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end

  defp fetch(_value, _key), do: nil

  defp fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      fetch_path(map, path)
    end)
  end

  defp fetch_any(_map, _paths), do: nil

  defp fetch_path(value, []), do: value

  defp fetch_path(value, [segment | rest]) do
    case fetch(value, segment) do
      nil -> nil
      next -> fetch_path(next, rest)
    end
  end

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(value), do: value

  defp first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  defp int_value(nil, default), do: default
  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> default
    end
  end

  defp int_value(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp json_error(conn, status, message) do
    json(conn, status, %{error: message})
  end
end
