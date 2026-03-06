defmodule LemonGateway.Transports.Webhook.Request do
  @moduledoc """
  Request parsing, authentication, and metadata helpers for the webhook transport.
  """

  alias Plug.Conn

  @sensitive_query_fragments [
    "token",
    "secret",
    "password",
    "auth",
    "authorization",
    "api_key",
    "apikey",
    "signature",
    "sig"
  ]

  @spec authorize_request(Conn.t(), map(), map(), map()) :: :ok | {:error, :unauthorized}
  def authorize_request(conn, _payload, integration, webhook_config) do
    expected = normalize_blank(fetch(integration, :token))

    provided =
      first_non_blank(
        [
          authorization_token(conn),
          List.first(Conn.get_req_header(conn, "x-webhook-token"))
        ] ++
          optional_values(allow_query_token?(integration, webhook_config), [query_token(conn)]) ++
          optional_values(allow_payload_token?(integration, webhook_config), [payload_token(conn)])
      )

    if secure_compare(expected, provided) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @spec normalize_payload(map()) ::
          {:ok,
           %{prompt: binary(), prompt_text: binary() | nil, attachments: list(), metadata: map()}}
          | {:error, :unprocessable_entity}
  def normalize_payload(payload) when is_map(payload) do
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

  def normalize_payload(_), do: {:error, :unprocessable_entity}

  @spec secure_compare(binary() | nil, binary() | nil) :: boolean()
  def secure_compare(expected, provided)
      when is_binary(expected) and is_binary(provided) and
             byte_size(expected) == byte_size(provided) do
    Plug.Crypto.secure_compare(expected, provided)
  rescue
    _ -> false
  end

  def secure_compare(_, _), do: false

  @spec validate_callback_url(binary() | nil, boolean(), keyword()) ::
          {:ok, binary() | nil} | {:error, :invalid_callback_url}
  def validate_callback_url(callback_url, allow_private_hosts, opts \\ [])

  def validate_callback_url(nil, _allow_private_hosts, _opts), do: {:ok, nil}
  def validate_callback_url("", _allow_private_hosts, _opts), do: {:ok, nil}

  def validate_callback_url(callback_url, allow_private_hosts, opts)
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

  def validate_callback_url(_callback_url, _allow_private_hosts, _opts),
    do: {:error, :invalid_callback_url}

  @spec request_metadata(Conn.t()) :: map()
  def request_metadata(conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      query: redact_query_string(conn.query_string),
      remote_ip: remote_ip_to_string(conn.remote_ip),
      user_agent: List.first(Conn.get_req_header(conn, "user-agent")),
      request_id: List.first(Conn.get_req_header(conn, "x-request-id"))
    }
  end

  @spec resolve_callback_url(map(), map(), map()) :: binary() | nil
  def resolve_callback_url(payload, integration, webhook_config) do
    configured_callback_url =
      first_non_blank([
        fetch(integration, :callback_url),
        fetch(webhook_config, :callback_url)
      ])

    if allow_callback_override?(integration, webhook_config) do
      first_non_blank([payload_callback_url(payload), configured_callback_url])
    else
      configured_callback_url
    end
  end

  @spec resolve_callback_wait_timeout_ms(map(), map(), pos_integer()) :: pos_integer()
  def resolve_callback_wait_timeout_ms(integration, webhook_config, default_timeout_ms) do
    integration_timeout = int_value(fetch(integration, :callback_wait_timeout_ms), nil)
    webhook_timeout = int_value(fetch(webhook_config, :callback_wait_timeout_ms), nil)

    (integration_timeout || webhook_timeout || default_timeout_ms)
    |> max(1)
  end

  @spec fetch(term(), atom() | binary()) :: term()
  def fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  def fetch(list, key) when is_list(list),
    do: Keyword.get(list, key) || Keyword.get(list, to_string(key))

  def fetch(_value, _key), do: nil

  @spec normalize_blank(term()) :: term()
  def normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_blank(value), do: value

  @spec int_value(term(), term()) :: integer() | term()
  def int_value(nil, default), do: default
  def int_value(value, _default) when is_integer(value), do: value

  def int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> default
    end
  end

  def int_value(_value, default), do: default

  defp allow_callback_override?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_callback_override, false)

  defp allow_query_token?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_query_token, false)

  defp allow_payload_token?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_payload_token, false)

  defp resolve_flag(integration, webhook_config, key, default) do
    [fetch(integration, key), fetch(webhook_config, key)]
    |> Enum.find_value(default, &bool_value/1)
  end

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  defp bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  defp bool_value(_value), do: nil

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
    |> Conn.fetch_query_params()
    |> Map.get(:query_params, %{})
    |> normalize_map()
  rescue
    _ -> %{}
  end

  defp body_params(%Conn{body_params: %Conn.Unfetched{}}), do: %{}
  defp body_params(%Conn{body_params: params}) when is_map(params), do: params
  defp body_params(_), do: %{}

  defp authorization_token(conn) do
    conn
    |> Conn.get_req_header("authorization")
    |> List.first()
    |> normalize_blank()
    |> case do
      nil -> nil
      "Bearer " <> token -> normalize_blank(token)
      "bearer " <> token -> normalize_blank(token)
      token -> normalize_blank(token)
    end
  end

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

  defp payload_callback_url(payload) do
    first_non_blank([
      fetch_any(payload, [["callback_url"]]),
      fetch_any(payload, [["callbackUrl"]]),
      fetch_any(payload, [["callback", "url"]])
    ])
  end

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
  defp normalize_resolved_ip(ip) when is_binary(ip), do: parse_ip(ip)
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
    Enum.any?(@sensitive_query_fragments, &String.contains?(normalized_key, &1))
  end

  defp remote_ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp remote_ip_to_string({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp remote_ip_to_string(_), do: nil

  defp fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path -> fetch_path(map, path) end)
  end

  defp fetch_any(_map, _paths), do: nil

  defp fetch_path(value, []), do: value

  defp fetch_path(value, [segment | rest]) do
    case fetch(value, segment) do
      nil -> nil
      next -> fetch_path(next, rest)
    end
  end

  defp first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

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
end
