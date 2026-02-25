defmodule LemonGateway.Transports.Webhook do
  @moduledoc """
  HTTP webhook transport for LemonGateway. Accepts prompt submissions via
  POST requests with support for synchronous and asynchronous response modes,
  callback delivery with retries, token-based authentication, and idempotency keys.
  """

  use Plug.Router
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Runtime
  alias LemonCore.Store
  alias LemonGateway.Types.Job
  alias LemonCore.{Id, SessionKey}

  @default_timeout_ms 30_000
  @default_callback_wait_timeout_ms 10 * 60 * 1000
  @default_callback_max_attempts 3
  @default_callback_backoff_ms 500
  @default_callback_backoff_max_ms 5_000
  @callback_waiter_ready_timeout_ms 1_000
  @idempotency_table :webhook_idempotency
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
         {:ok, idempotency_ctx} <- idempotency_context(conn, payload, integration_id, integration),
         {:ok, run_ctx} <-
           submit_run(conn, integration_id, integration, payload, normalized, idempotency_ctx),
         {:ok, status, response_payload} <- response_for_run(run_ctx) do
      maybe_store_idempotency_response(idempotency_ctx, status, response_payload)
      json(conn, status, response_payload)
    else
      nil ->
        json_error(conn, 404, "integration not found")

      {:error, :unauthorized} ->
        json_error(conn, 401, "unauthorized")

      {:error, :unprocessable_entity} ->
        json_error(conn, 422, "invalid request payload")

      {:error, :invalid_callback_url} ->
        json_error(conn, 422, "invalid callback url")

      {:error, :run_timeout} ->
        json_error(conn, 500, "run timed out")

      {:duplicate, status, response_payload} ->
        json(conn, status, response_payload)

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
      fallback = Application.get_env(:lemon_gateway, :enable_webhook, false)
      (resolve_from_app_config(:enable_webhook) || fallback) == true
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
        resolve_from_app_config(:webhook) || Application.get_env(:lemon_gateway, :webhook, %{})
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

  @doc false
  def callback_success_status_for_test(status), do: callback_success_status?(status)

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts) do
    validate_callback_url(callback_url, allow_private_hosts, [])
  end

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts, opts)
      when is_list(opts) do
    validate_callback_url(callback_url, allow_private_hosts, opts)
  end

  @doc false
  def request_metadata_for_test(conn), do: request_metadata(conn)

  @doc false
  def resolve_callback_wait_timeout_ms_for_test(integration, webhook_config \\ %{}) do
    resolve_callback_wait_timeout_ms(integration, webhook_config)
  end

  @doc false
  def authorize_request_for_test(conn, payload, integration) do
    authorize_request(conn, payload, integration)
  end

  @doc false
  def idempotency_context_for_test(conn, payload, integration_id, integration) do
    idempotency_context(conn, payload, integration_id, integration)
  end

  @doc false
  def idempotency_table_for_test, do: @idempotency_table

  defp response_for_run(%{mode: :sync} = run_ctx) do
    with_sync_subscription(run_ctx, fn ->
      case wait_for_run_completion(run_ctx.run_id, run_ctx.timeout_ms, subscribe?: false) do
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
    end)
  end

  defp response_for_run(run_ctx) do
    payload =
      %{
        run_id: run_ctx.run_id,
        session_key: run_ctx.session_key,
        mode: "async",
        status: "accepted"
      }
      |> maybe_put(:callback, run_ctx.callback_status)

    {:ok, 202, payload}
  end

  defp submit_run(conn, integration_id, integration, payload, normalized, idempotency_ctx) do
    run_id = Id.run_id()
    session_key = resolve_session_key(integration)
    mode = resolve_mode(integration)
    timeout_ms = resolve_timeout_ms(integration)
    callback_wait_timeout_ms = resolve_callback_wait_timeout_ms(integration)
    queue_mode = resolve_queue_mode(integration)
    callback_retry = callback_retry_config(integration)
    allow_private_callback_hosts = allow_private_callback_hosts?(integration)

    with {:ok, callback_url} <-
           payload
           |> resolve_callback_url(integration)
           |> validate_callback_url(allow_private_callback_hosts),
         {:ok, wait_setup, callback_status} <-
           prepare_wait_before_submit(mode, %{
             integration_id: integration_id,
             run_id: run_id,
             session_key: session_key,
             timeout_ms: timeout_ms,
             callback_wait_timeout_ms: callback_wait_timeout_ms,
             callback_url: callback_url,
             metadata: normalized.metadata,
             attachments: normalized.attachments,
             callback_retry: callback_retry
           }) do
      job =
        build_submit_job(conn, integration_id, integration, normalized, run_id, session_key, queue_mode)

      run_ctx = %{
        integration_id: integration_id,
        run_id: run_id,
        session_key: session_key,
        mode: mode,
        timeout_ms: timeout_ms,
        callback_wait_timeout_ms: callback_wait_timeout_ms,
        callback_url: callback_url,
        metadata: normalized.metadata,
        attachments: normalized.attachments,
        callback_retry: callback_retry,
        callback_status: callback_status
      }

      perform_submit(job, run_ctx, wait_setup, idempotency_ctx)
    end
  end

  defp build_submit_job(conn, integration_id, integration, normalized, run_id, session_key, queue_mode) do
    %Job{
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
  end

  defp perform_submit(job, run_ctx, wait_setup, idempotency_ctx) do
    try do
      :ok = Runtime.submit(job)
      maybe_store_idempotency_submission(idempotency_ctx, run_ctx.run_id, run_ctx.session_key, run_ctx.mode)
      {:ok, Map.merge(run_ctx, wait_setup)}
    rescue
      error ->
        cleanup_wait_setup(wait_setup)
        {:error, {:submit_failed, Exception.message(error)}}
    end
  end

  defp integration_metadata(integration) do
    callback_retry = callback_retry_config(integration)

    %{
      session_key: fetch(integration, :session_key),
      agent_id: fetch(integration, :agent_id),
      queue_mode: resolve_queue_mode(integration),
      default_engine: resolve_engine(integration),
      cwd: normalize_blank(fetch(integration, :cwd)),
      callback_url_configured: is_binary(normalize_blank(fetch(integration, :callback_url))),
      allow_callback_override: allow_callback_override?(integration),
      allow_private_callback_hosts: allow_private_callback_hosts?(integration),
      callback_max_attempts: callback_retry.max_attempts,
      callback_backoff_ms: callback_retry.backoff_ms,
      callback_backoff_max_ms: callback_retry.backoff_max_ms,
      mode: resolve_mode(integration),
      timeout_ms: resolve_timeout_ms(integration),
      callback_wait_timeout_ms: resolve_callback_wait_timeout_ms(integration),
      allow_query_token: allow_query_token?(integration),
      allow_payload_token: allow_payload_token?(integration),
      allow_payload_idempotency_key: allow_payload_idempotency_key?(integration)
    }
  end

  defp authorize_request(conn, _payload, integration) do
    expected = normalize_blank(fetch(integration, :token))

    provided =
      first_non_blank(
        [
          authorization_token(conn),
          List.first(Plug.Conn.get_req_header(conn, "x-webhook-token"))
        ] ++
          optional_values(allow_query_token?(integration), [query_token(conn)]) ++
          optional_values(allow_payload_token?(integration), [payload_token(conn)])
      )

    if secure_compare(expected, provided) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp optional_values(true, values) when is_list(values), do: values
  defp optional_values(_, _), do: []

  defp query_token(conn) do
    fetch_any(query_params(conn), [["token"], ["webhook_token"]])
  end

  defp payload_token(conn) do
    fetch_any(body_params(conn), [["token"], ["webhook_token"]])
  end

  defp query_params(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.get(:query_params, %{})
    |> normalize_map()
  rescue
    _ -> %{}
  end

  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_params(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp body_params(_), do: %{}

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

  defp normalize_mode_string(mode) when mode in [:sync, :async], do: Atom.to_string(mode)
  defp normalize_mode_string(mode) when mode in ["sync", "async"], do: mode
  defp normalize_mode_string(_), do: nil

  defp resolve_timeout_ms(integration) do
    integration_timeout = int_value(fetch(integration, :timeout_ms), nil)
    webhook_timeout = int_value(fetch(config(), :timeout_ms), nil)

    integration_timeout || webhook_timeout || @default_timeout_ms
  end

  defp resolve_callback_wait_timeout_ms(integration) do
    resolve_callback_wait_timeout_ms(integration, config())
  end

  defp resolve_callback_wait_timeout_ms(integration, webhook_config) do
    integration_timeout = int_value(fetch(integration, :callback_wait_timeout_ms), nil)
    webhook_timeout = int_value(fetch(webhook_config, :callback_wait_timeout_ms), nil)

    (integration_timeout || webhook_timeout || @default_callback_wait_timeout_ms)
    |> max(1)
  end

  defp callback_retry_config(integration) do
    max_attempts =
      int_value(
        first_non_blank([
          fetch(integration, :callback_max_attempts),
          fetch(config(), :callback_max_attempts)
        ]),
        @default_callback_max_attempts
      )
      |> max(1)

    backoff_ms =
      int_value(
        first_non_blank([
          fetch(integration, :callback_backoff_ms),
          fetch(config(), :callback_backoff_ms)
        ]),
        @default_callback_backoff_ms
      )
      |> max(0)

    backoff_max_ms =
      int_value(
        first_non_blank([
          fetch(integration, :callback_backoff_max_ms),
          fetch(config(), :callback_backoff_max_ms)
        ]),
        @default_callback_backoff_max_ms
      )
      |> max(backoff_ms)

    %{max_attempts: max_attempts, backoff_ms: backoff_ms, backoff_max_ms: backoff_max_ms}
  end

  defp resolve_callback_url(payload, integration) do
    configured_callback_url =
      first_non_blank([
        fetch(integration, :callback_url),
        fetch(config(), :callback_url)
      ])

    if allow_callback_override?(integration) do
      first_non_blank([payload_callback_url(payload), configured_callback_url])
    else
      configured_callback_url
    end
  end

  defp payload_callback_url(payload) do
    first_non_blank([
      fetch_any(payload, [["callback_url"]]),
      fetch_any(payload, [["callbackUrl"]]),
      fetch_any(payload, [["callback", "url"]])
    ])
  end

  defp allow_callback_override?(integration),
    do: resolve_integration_flag(integration, :allow_callback_override)

  defp allow_private_callback_hosts?(integration),
    do: resolve_integration_flag(integration, :allow_private_callback_hosts)

  defp allow_query_token?(integration),
    do: resolve_integration_flag(integration, :allow_query_token)

  defp allow_payload_token?(integration),
    do: resolve_integration_flag(integration, :allow_payload_token)

  defp allow_payload_idempotency_key?(integration),
    do: resolve_integration_flag(integration, :allow_payload_idempotency_key)

  defp resolve_integration_flag(integration, key) do
    resolve_boolean([fetch(integration, key), fetch(config(), key)], false)
  end

  defp validate_callback_url(callback_url, allow_private_hosts) do
    validate_callback_url(callback_url, allow_private_hosts, [])
  end

  defp validate_callback_url(nil, _allow_private_hosts, _opts), do: {:ok, nil}
  defp validate_callback_url("", _allow_private_hosts, _opts), do: {:ok, nil}

  defp validate_callback_url(callback_url, allow_private_hosts, opts)
       when is_binary(callback_url) and is_list(opts) do
    normalized = normalize_blank(callback_url)

    with value when is_binary(value) <- normalized,
         %URI{scheme: scheme, host: host} = uri <- URI.parse(value),
         normalized_scheme when normalized_scheme in ["http", "https"] <-
           String.downcase(to_string(scheme)),
         canonical_host when is_binary(canonical_host) <- canonicalize_host(host),
         true <- allow_private_hosts || not private_callback_host?(canonical_host, opts) do
      {:ok, URI.to_string(%{uri | host: canonical_host})}
    else
      _ -> {:error, :invalid_callback_url}
    end
  rescue
    _ -> {:error, :invalid_callback_url}
  end

  defp validate_callback_url(_callback_url, _allow_private_hosts, _opts),
    do: {:error, :invalid_callback_url}

  defp private_callback_host?(host, opts) when is_binary(host) and is_list(opts) do
    canonical_host = canonicalize_host(host)

    cond do
      not is_binary(canonical_host) ->
        true

      localhost_variant?(canonical_host) ->
        true

      true ->
        case parse_ip(canonical_host) do
          nil ->
            canonical_host
            |> resolve_host_ips(opts)
            |> Enum.any?(&private_ip?/1)

          ip ->
            private_ip?(ip)
        end
    end
  end

  defp private_callback_host?(_, _), do: true

  defp localhost_variant?(host) when is_binary(host) do
    host in [
      "localhost",
      "localhost.localdomain",
      "localhost6",
      "ip6-localhost",
      "ip6-loopback"
    ] or String.ends_with?(host, ".localhost")
  end

  defp localhost_variant?(_), do: false

  defp resolve_host_ips(host, opts) when is_binary(host) and is_list(opts) do
    resolver = Keyword.get(opts, :dns_resolver, &default_dns_resolver/1)

    case resolver.(host) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_resolved_ip/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp resolve_host_ips(_, _), do: []

  defp default_dns_resolver(host) when is_binary(host) do
    host_charlist = String.to_charlist(host)

    resolve_addrs(host_charlist, :inet) ++ resolve_addrs(host_charlist, :inet6)
  end

  defp default_dns_resolver(_), do: []

  defp resolve_addrs(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addrs} when is_list(addrs) -> addrs
      _ -> []
    end
  end

  defp normalize_resolved_ip(ip) when is_tuple(ip), do: ip

  defp normalize_resolved_ip(ip) when is_binary(ip) do
    parse_ip(ip)
  end

  defp normalize_resolved_ip(_), do: nil

  defp private_ip?({a, _b, _c, _d}) when a in [0, 10, 127], do: true
  defp private_ip?({169, 254, _c, _d}), do: true
  defp private_ip?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ip?({192, 168, _c, _d}), do: true
  defp private_ip?({100, b, _c, _d}) when b in 64..127, do: true
  defp private_ip?({255, _b, _c, _d}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 65_535, a, b}) do
    private_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})
  end

  defp private_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip?(_), do: false

  defp prepare_wait_before_submit(:sync, %{run_id: run_id}) do
    topic = LemonCore.Bus.run_topic(run_id)
    :ok = LemonCore.Bus.subscribe(topic)
    {:ok, %{sync_topic: topic}, nil}
  rescue
    error ->
      {:error, {:wait_prepare_failed, Exception.message(error)}}
  end

  defp prepare_wait_before_submit(:async, %{callback_url: callback_url} = run_ctx)
       when is_binary(callback_url) and callback_url != "" do
    start_async_callback_waiter(run_ctx)
  end

  defp prepare_wait_before_submit(_mode, _run_ctx), do: {:ok, %{}, nil}

  defp start_async_callback_waiter(run_ctx) do
    parent = self()
    ready_ref = make_ref()

    case Task.start(fn -> async_callback_waiter(parent, ready_ref, run_ctx) end) do
      {:ok, pid} ->
        receive do
          {^ready_ref, :subscribed} ->
            {:ok, %{callback_waiter_pid: pid}, %{status: "scheduled", url: run_ctx.callback_url}}

          {^ready_ref, {:error, reason}} ->
            {:error, reason}
        after
          @callback_waiter_ready_timeout_ms ->
            Process.exit(pid, :kill)
            {:error, :callback_waiter_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp async_callback_waiter(parent, ready_ref, run_ctx) do
    topic = LemonCore.Bus.run_topic(run_ctx.run_id)

    case LemonCore.Bus.subscribe(topic) do
      :ok ->
        send(parent, {ready_ref, :subscribed})

        try do
          deliver_callback_after_completion(run_ctx)
        after
          _ = LemonCore.Bus.unsubscribe(topic)
        end

      error ->
        send(parent, {ready_ref, {:error, error}})
    end
  rescue
    error ->
      send(parent, {ready_ref, {:error, {:callback_waiter_failed, Exception.message(error)}}})
  end

  @spec deliver_callback_after_completion(map()) :: :ok | {:error, term()}
  defp deliver_callback_after_completion(run_ctx) do
    with {:ok, run_payload} <-
           wait_for_run_completion(run_ctx.run_id, run_ctx.callback_wait_timeout_ms,
             subscribe?: false
           ),
         {:ok, _status} <-
           send_callback_with_retry(
             run_ctx.callback_url,
             callback_payload(run_ctx, run_payload),
             run_ctx.timeout_ms,
             run_ctx.callback_retry
           ) do
      :ok
    else
      {:error, :timeout} ->
        Logger.warning("webhook callback wait timed out for run_id=#{run_ctx.run_id}")

      {:error, reason} ->
        Logger.warning(
          "webhook callback failed for run_id=#{run_ctx.run_id}: #{inspect(reason)}"
        )
    end
  end

  defp cleanup_wait_setup(%{sync_topic: topic}) when is_binary(topic) do
    _ = LemonCore.Bus.unsubscribe(topic)
    :ok
  end

  defp cleanup_wait_setup(%{callback_waiter_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp cleanup_wait_setup(_wait_setup), do: :ok

  defp with_sync_subscription(%{sync_topic: topic}, callback) when is_binary(topic) do
    try do
      callback.()
    after
      _ = LemonCore.Bus.unsubscribe(topic)
    end
  end

  defp with_sync_subscription(_run_ctx, callback), do: callback.()

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
        if callback_success_status?(status) do
          {:ok, status}
        else
          {:error, {:unexpected_status, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:callback_failed, Exception.message(error)}}
  end

  defp send_callback(_callback_url, _payload, _timeout_ms), do: {:error, :invalid_callback_url}

  defp send_callback_with_retry(callback_url, payload, timeout_ms, retry_config) do
    send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, 1)
  end

  defp send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, attempt) do
    case send_callback(callback_url, payload, timeout_ms) do
      {:ok, status} ->
        {:ok, status}

      {:error, _reason} = error ->
        if attempt >= retry_config.max_attempts do
          error
        else
          Process.sleep(backoff_delay_ms(retry_config, attempt))
          send_callback_with_retry(callback_url, payload, timeout_ms, retry_config, attempt + 1)
        end
    end
  end

  defp backoff_delay_ms(retry_config, attempt) do
    scaled = trunc(retry_config.backoff_ms * :math.pow(2, max(attempt - 1, 0)))
    min(scaled, retry_config.backoff_max_ms)
  end

  defp callback_success_status?(status) when is_integer(status), do: status in 200..299
  defp callback_success_status?(_status), do: false

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
      query: redact_query_string(conn.query_string),
      remote_ip: remote_ip_to_string(conn.remote_ip),
      user_agent: List.first(Plug.Conn.get_req_header(conn, "user-agent")),
      request_id: List.first(Plug.Conn.get_req_header(conn, "x-request-id"))
    }
  end

  defp idempotency_context(conn, payload, integration_id, integration) do
    case resolve_idempotency_key(conn, payload, integration) do
      nil ->
        {:ok, nil}

      idempotency_key ->
        store_key = idempotency_store_key(integration_id, idempotency_key)

        :global.trans({{__MODULE__, :idempotency, store_key}, self()}, fn ->
          case idempotency_response(integration_id, idempotency_key) do
            {:duplicate, _status, _payload} = duplicate ->
              duplicate

            nil ->
              _ =
                Store.put(@idempotency_table, store_key, %{
                  idempotency_key: idempotency_key,
                  integration_id: integration_id,
                  state: "pending",
                  updated_at_ms: System.system_time(:millisecond)
                })

              {:ok,
               %{
                 integration_id: integration_id,
                 idempotency_key: idempotency_key,
                 store_key: store_key
               }}
          end
        end)
    end
  end

  defp resolve_idempotency_key(conn, _payload, integration) do
    first_non_blank(
      [idempotency_header(conn)] ++
        optional_values(allow_payload_idempotency_key?(integration), [
          payload_idempotency_key(conn)
        ])
    )
  end

  defp idempotency_header(conn) do
    conn
    |> Plug.Conn.get_req_header("idempotency-key")
    |> List.first()
    |> normalize_blank()
  end

  defp payload_idempotency_key(conn) do
    fetch_any(body_params(conn), [
      ["idempotency_key"],
      ["idempotencyKey"],
      ["idempotency", "key"]
    ])
  end

  defp idempotency_response(integration_id, idempotency_key)
       when is_binary(integration_id) and is_binary(idempotency_key) do
    case Store.get(@idempotency_table, idempotency_store_key(integration_id, idempotency_key)) do
      %{} = entry ->
        response_status = int_value(fetch(entry, :response_status), nil)
        response_payload = fetch(entry, :response_payload)
        state = normalize_blank(fetch(entry, :state))

        cond do
          is_integer(response_status) and is_map(response_payload) ->
            {:duplicate, response_status, response_payload}

          state == "pending" ->
            idempotency_pending_response(entry)

          true ->
            idempotency_fallback_response(entry)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp idempotency_response(_, _), do: nil

  defp idempotency_pending_response(entry) do
    pending_payload =
      case idempotency_fallback_payload(entry) do
        %{} = payload -> Map.put_new(payload, :status, "processing")
        _ -> %{status: "processing"}
      end

    {:duplicate, 202, pending_payload}
  end

  defp idempotency_fallback_response(entry) do
    case idempotency_fallback_payload(entry) do
      %{} = payload -> {:duplicate, 202, payload}
      _ -> nil
    end
  end

  defp idempotency_fallback_payload(entry) when is_map(entry) do
    run_id = normalize_blank(fetch(entry, :run_id))
    session_key = normalize_blank(fetch(entry, :session_key))

    if is_binary(run_id) and is_binary(session_key) do
      %{
        run_id: run_id,
        session_key: session_key
      }
      |> maybe_put(:mode, normalize_mode_string(fetch(entry, :mode)))
      |> maybe_put(:status, "accepted")
    end
  end

  defp idempotency_fallback_payload(_), do: nil

  defp maybe_store_idempotency_submission(nil, _run_id, _session_key, _mode), do: :ok

  defp maybe_store_idempotency_submission(%{} = idempotency_ctx, run_id, session_key, mode) do
    entry =
      %{
        run_id: run_id,
        session_key: session_key,
        mode: normalize_mode_string(mode),
        idempotency_key: idempotency_ctx.idempotency_key,
        integration_id: idempotency_ctx.integration_id,
        state: "submitted",
        updated_at_ms: System.system_time(:millisecond)
      }

    merge_store_idempotency_entry(idempotency_ctx, entry)
  end

  defp maybe_store_idempotency_submission(_idempotency_ctx, _run_id, _session_key, _mode), do: :ok

  defp maybe_store_idempotency_response(nil, _status, _payload), do: :ok

  defp maybe_store_idempotency_response(%{} = idempotency_ctx, status, payload)
       when is_integer(status) and is_map(payload) do
    merge_store_idempotency_entry(idempotency_ctx, %{
      response_status: status,
      response_payload: payload,
      state: "completed",
      updated_at_ms: System.system_time(:millisecond)
    })
  end

  defp maybe_store_idempotency_response(_idempotency_ctx, _status, _payload), do: :ok

  defp merge_store_idempotency_entry(%{store_key: store_key} = idempotency_ctx, entry)
       when is_tuple(store_key) and is_map(entry) do
    merged_entry =
      case Store.get(@idempotency_table, store_key) do
        %{} = existing -> Map.merge(existing, entry)
        _ -> Map.merge(entry, %{idempotency_key: idempotency_ctx.idempotency_key})
      end

    case Store.put(@idempotency_table, store_key, merged_entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("webhook idempotency store write failed: #{inspect(reason)}")
        :ok

      other ->
        Logger.warning("webhook idempotency store returned unexpected result: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("webhook idempotency store failed: #{Exception.message(error)}")
      :ok
  end

  defp merge_store_idempotency_entry(_idempotency_ctx, _entry), do: :ok

  defp idempotency_store_key(integration_id, idempotency_key) do
    {to_string(integration_id), to_string(idempotency_key)}
  end

  defp redact_query_string(value) when value in [nil, ""], do: nil

  defp redact_query_string(value) when is_binary(value) do
    value
    |> URI.query_decoder()
    |> Enum.map(fn {key, query_value} ->
      if sensitive_query_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, query_value}
      end
    end)
    |> URI.encode_query()
  rescue
    _ -> "[REDACTED]"
  end

  defp redact_query_string(_value), do: nil

  defp sensitive_query_key?(key) do
    normalized_key = String.downcase(to_string(key))

    Enum.any?(
      [
        "token",
        "secret",
        "password",
        "auth",
        "authorization",
        "api_key",
        "apikey",
        "signature",
        "sig"
      ],
      &String.contains?(normalized_key, &1)
    )
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

  defp wait_for_run_completion(run_id, timeout_ms, opts \\ [])

  defp wait_for_run_completion(run_id, timeout_ms, opts)
       when is_binary(run_id) and is_list(opts) do
    topic = LemonCore.Bus.run_topic(run_id)
    subscribe? = Keyword.get(opts, :subscribe?, true)
    timeout_ms = int_value(timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if subscribe? do
      :ok = LemonCore.Bus.subscribe(topic)
    end

    try do
      wait_for_run_completion_loop(deadline)
    after
      if subscribe? do
        _ = LemonCore.Bus.unsubscribe(topic)
      end
    end
  rescue
    error ->
      {:error, {:wait_failed, Exception.message(error)}}
  end

  defp wait_for_run_completion(_run_id, _timeout_ms, _opts), do: {:error, :invalid_run_id}

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

  defp canonicalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> normalize_blank()
  end

  defp canonicalize_host(_), do: nil

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

  defp default_engine do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:default_engine) || "lemon"
    else
      resolve_from_app_config(:default_engine) || "lemon"
    end
  rescue
    _ -> "lemon"
  end

  # Resolves a config key from the LemonGateway.Config app env (keyword or map)
  # when the Config GenServer is not running.
  defp resolve_from_app_config(key) do
    cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

    cond do
      is_list(cfg) and Keyword.keyword?(cfg) -> Keyword.get(cfg, key)
      is_map(cfg) -> fetch(cfg, key)
      true -> nil
    end
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

  defp resolve_boolean(values, default) when is_list(values) do
    Enum.find_value(values, default, fn value ->
      bool_value(value)
    end)
  end

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  defp bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  defp bool_value(_value), do: nil

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
