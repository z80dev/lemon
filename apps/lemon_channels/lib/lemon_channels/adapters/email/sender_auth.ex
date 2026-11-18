defmodule LemonChannels.Adapters.Email.SenderAuth do
  @moduledoc """
  Decides whether an inbound email's sender may reach the agent.

  The webhook token authenticates the *provider*; it says nothing about who
  wrote the mail. Anyone can put any address in `From`, so the sender is
  authorized separately, before the message is normalized, threaded, stored or
  submitted:

    1. **Allowlist.** The bare `From` mailbox address must be listed in
       `gateway.email.inbound.allowed_senders` (exact, case-insensitive). A
       missing, empty or malformed list refuses every sender.
    2. **Provider verdicts.** When the payload carries an RFC 8601
       `Authentication-Results` verdict reporting `dmarc=fail` for the `From`
       domain, the message is refused. A failure can only be reported about the
       message itself, so this never needs configuration.
    3. **Required attestation (default).** `gateway.email.inbound.authserv_id`
       names the authserv-id the provider stamps, and the first
       `Authentication-Results` header stamped with exactly that id must report
       `dmarc=pass header.from=<From domain>` or `dkim=pass` whose `header.d`
       (or `header.i` domain) equals the `From` domain. SPF alone never counts:
       it authenticates the envelope sender, not `From`. A missing, foreign or
       non-aligned verdict is refused. **Without `authserv_id` every sender is
       refused**, as is a malformed `authserv_id` or `sender_auth` value.

  The only way to admit mail without a verdict is the explicit, unsafe opt-out
  `gateway.email.inbound.sender_auth = "from_only_unsafe"` (with no
  `authserv_id`), for providers that stamp no verdict at all. The allowlisted
  `From` is then the only check, so anyone who forges that address reaches the
  agent; `config_warnings/1` reports it and the adapter logs it at startup.

  Only the first header with the pinned authserv-id is trusted: a receiving
  MTA prepends its own header above whatever the sender wrote, so a forged copy
  lower down never overrides it. This relies on the provider stamping every
  message it delivers (and, per RFC 8601 section 5, removing inbound headers
  that claim its id); `authserv_id` must only be set to an id the provider
  actually stamps.

  Verdicts are read from, in order: an `authentication_results` /
  `Authentication-Results` payload field (string or list); a raw `headers`
  block, a `headers` map, or a `Headers` list of `%{"Name", "Value"}` objects;
  and `message-headers` (`[name, value]` pairs, as a list or a JSON string).
  """

  alias LemonChannels.Adapters.Email.Config

  @type reason ::
          :no_allowed_senders
          | :sender_not_allowed
          | :authentication_missing
          | :authentication_failed
          | :authserv_id_missing
          | :authserv_id_invalid
          | :sender_auth_invalid

  @result_field_keys [
    "authentication_results",
    "Authentication-Results",
    "authentication-results"
  ]
  @header_field_keys ["headers", "Headers"]
  @header_pair_keys ["message-headers", "message_headers"]
  @header_name "authentication-results"

  @doc """
  Authorizes `from` (a bare, lowercased mailbox address) for the raw provider
  payload `raw` against the email config `cfg`.
  """
  @spec authorize(binary() | nil, map(), map()) :: :ok | {:error, reason()}
  def authorize(from, raw, cfg) when is_binary(from) and is_map(raw) and is_map(cfg) do
    sender = from |> String.trim() |> String.downcase()

    with :ok <- check_allowlist(sender, Config.allowed_senders(cfg)) do
      domain = domain(sender)
      verdicts = verdicts(raw)

      with :ok <- refuse_dmarc_failure(verdicts, domain) do
        check_attestation(Config.sender_attestation(cfg), verdicts, domain)
      end
    end
  end

  def authorize(_from, _raw, _cfg), do: {:error, :sender_not_allowed}

  @doc """
  Operator-facing warnings about the inbound sender policy in `cfg`: an empty
  allowlist, a configuration that refuses all mail, or the unsafe opt-out.
  Logged by `LemonChannels.Adapters.Email` when the webhook is registered.
  """
  @spec config_warnings(map()) :: [binary()]
  def config_warnings(cfg) when is_map(cfg) do
    allowlist =
      if Config.allowed_senders(cfg) == [],
        do: [
          "email inbound: gateway.email.inbound.allowed_senders is empty; every inbound message is refused (403)"
        ],
        else: []

    attestation =
      case Config.sender_attestation(cfg) do
        {:required, _authserv_id} ->
          []

        :from_only_unsafe ->
          [
            "email inbound: UNSAFE sender_auth = \"from_only_unsafe\": no provider authentication is checked, " <>
              "so anyone who forges an allowlisted From address can run the agent"
          ]

        {:invalid, reason} ->
          [
            "email inbound: sender authentication is not configured (#{reason}); every inbound message is refused (403). " <>
              "Set gateway.email.inbound.authserv_id to your provider's Authentication-Results id"
          ]
      end

    allowlist ++ attestation
  end

  def config_warnings(_cfg), do: config_warnings(%{})

  defp check_allowlist(_sender, []), do: {:error, :no_allowed_senders}

  defp check_allowlist(sender, allowed) do
    if sender in allowed, do: :ok, else: {:error, :sender_not_allowed}
  end

  defp refuse_dmarc_failure(verdicts, domain) do
    failed? =
      Enum.any?(verdicts, fn %{results: results} ->
        Enum.any?(results, fn result ->
          result.method == "dmarc" and result.result == "fail" and
            Map.get(result.props, "header.from", domain) == domain
        end)
      end)

    if failed?, do: {:error, :authentication_failed}, else: :ok
  end

  defp check_attestation(:from_only_unsafe, _verdicts, _domain), do: :ok
  defp check_attestation({:invalid, reason}, _verdicts, _domain), do: {:error, reason}

  defp check_attestation({:required, authserv_id}, verdicts, domain) do
    case Enum.find(verdicts, &(&1.authserv_id == authserv_id)) do
      nil ->
        {:error, :authentication_missing}

      %{results: results} ->
        if Enum.any?(results, &aligned_pass?(&1, domain)),
          do: :ok,
          else: {:error, :authentication_failed}
    end
  end

  defp aligned_pass?(%{method: "dmarc", result: "pass", props: props}, domain),
    do: Map.get(props, "header.from") == domain

  defp aligned_pass?(%{method: "dkim", result: "pass", props: props}, domain),
    do: Map.get(props, "header.d") == domain or domain(Map.get(props, "header.i")) == domain

  defp aligned_pass?(_result, _domain), do: false

  defp domain(address) when is_binary(address) do
    case String.split(address, "@") do
      [_ | _] = parts when length(parts) > 1 -> List.last(parts)
      _ -> nil
    end
  end

  defp domain(_address), do: nil

  # -- Locating Authentication-Results headers ---------------------------------

  defp verdicts(raw) do
    (field_values(raw) ++ header_values(raw) ++ pair_values(raw))
    |> Enum.flat_map(fn value ->
      case parse(value) do
        nil -> []
        verdict -> [verdict]
      end
    end)
  end

  defp field_values(raw) do
    Enum.flat_map(@result_field_keys, fn key -> raw |> Map.get(key) |> strings() end)
  end

  defp header_values(raw) do
    Enum.flat_map(@header_field_keys, fn key ->
      case Map.get(raw, key) do
        block when is_binary(block) ->
          if String.valid?(block), do: header_block_values(block), else: []

        %{} = headers ->
          header_map_values(headers)

        pairs when is_list(pairs) ->
          header_pair_values(pairs)

        _ ->
          []
      end
    end)
  end

  defp pair_values(raw) do
    Enum.flat_map(@header_pair_keys, fn key ->
      case Map.get(raw, key) do
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, pairs} when is_list(pairs) -> header_pair_values(pairs)
            _ -> []
          end

        pairs when is_list(pairs) ->
          header_pair_values(pairs)

        _ ->
          []
      end
    end)
  end

  defp header_block_values(block) do
    block
    |> String.replace(~r/\r?\n[ \t]+/, " ")
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> if header_name?(name), do: [value], else: []
        _ -> []
      end
    end)
  end

  defp header_map_values(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) -> if header_name?(name), do: strings(value), else: []
      _ -> []
    end)
  end

  defp header_pair_values(pairs) do
    Enum.flat_map(pairs, fn
      [name, value] when is_binary(name) and is_binary(value) ->
        if header_name?(name), do: [value], else: []

      %{} = header ->
        name = Map.get(header, "Name") || Map.get(header, "name")
        value = Map.get(header, "Value") || Map.get(header, "value")

        if is_binary(name) and is_binary(value) and header_name?(name), do: [value], else: []

      _ ->
        []
    end)
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings(_value), do: []

  defp header_name?(name),
    do: String.valid?(name) and name |> String.trim() |> String.downcase() == @header_name

  @doc false
  @spec parse(binary()) :: %{authserv_id: binary(), results: [map()]} | nil
  def parse(value) when is_binary(value) do
    with true <- String.valid?(value),
         {:ok, [[{authserv_id, false} | _version] | resinfos]} <- scan(value) do
      %{
        authserv_id: String.downcase(authserv_id),
        results: Enum.flat_map(resinfos, &resinfo/1)
      }
    else
      _ -> nil
    end
  end

  def parse(_value), do: nil

  # `method[/version]=result` followed by `ptype.property=value` pairs. A token
  # that came (even partly) from a quoted string is never a method spec, and
  # property names repeated later never override the first occurrence.
  defp resinfo([{spec, false} | props]) do
    case Regex.run(~r/\A([a-z0-9_.-]+)(?:\/[0-9]+)?=([a-z0-9_-]+)\z/i, spec) do
      [_, method, result] ->
        [
          %{
            method: String.downcase(method),
            result: String.downcase(result),
            props: Enum.reduce(props, %{}, &put_prop/2)
          }
        ]

      _ ->
        []
    end
  end

  defp resinfo(_tokens), do: []

  defp put_prop({token, _quoted?}, acc) do
    case String.split(token, "=", parts: 2) do
      [key, value] -> Map.put_new(acc, String.downcase(key), String.downcase(String.trim(value)))
      _ -> acc
    end
  end

  # Splits on `;` and whitespace outside quoted strings, drops (nested)
  # comments, and unquotes quoted strings. Unterminated quotes or comments make
  # the whole header unreadable, which callers treat as absent.
  defp scan(value), do: scan(value, :plain, [], [], nil)

  defp scan(<<>>, :plain, segments, tokens, current) do
    {:ok, Enum.reverse([Enum.reverse(push(tokens, current)) | segments])}
  end

  defp scan(<<>>, _mode, _segments, _tokens, _current), do: :error

  defp scan(<<?;, rest::binary>>, :plain, segments, tokens, current),
    do: scan(rest, :plain, [Enum.reverse(push(tokens, current)) | segments], [], nil)

  defp scan(<<?", rest::binary>>, :plain, segments, tokens, current),
    do: scan(rest, :quoted, segments, tokens, quoted(current))

  defp scan(<<?(, rest::binary>>, :plain, segments, tokens, current),
    do: scan(rest, {:comment, 1}, segments, push(tokens, current), nil)

  defp scan(<<c, rest::binary>>, :plain, segments, tokens, current) when c in ~c[ \t\r\n],
    do: scan(rest, :plain, segments, push(tokens, current), nil)

  defp scan(<<c, rest::binary>>, :plain, segments, tokens, current),
    do: scan(rest, :plain, segments, tokens, append(current, c))

  defp scan(<<?\\, c, rest::binary>>, :quoted, segments, tokens, current),
    do: scan(rest, :quoted, segments, tokens, append(current, c))

  defp scan(<<?", rest::binary>>, :quoted, segments, tokens, current),
    do: scan(rest, :plain, segments, tokens, current)

  defp scan(<<c, rest::binary>>, :quoted, segments, tokens, current),
    do: scan(rest, :quoted, segments, tokens, append(current, c))

  defp scan(<<?\\, _c, rest::binary>>, {:comment, depth}, segments, tokens, current),
    do: scan(rest, {:comment, depth}, segments, tokens, current)

  defp scan(<<?(, rest::binary>>, {:comment, depth}, segments, tokens, current),
    do: scan(rest, {:comment, depth + 1}, segments, tokens, current)

  defp scan(<<?), rest::binary>>, {:comment, 1}, segments, tokens, current),
    do: scan(rest, :plain, segments, tokens, current)

  defp scan(<<?), rest::binary>>, {:comment, depth}, segments, tokens, current),
    do: scan(rest, {:comment, depth - 1}, segments, tokens, current)

  defp scan(<<_c, rest::binary>>, {:comment, depth}, segments, tokens, current),
    do: scan(rest, {:comment, depth}, segments, tokens, current)

  defp push(tokens, nil), do: tokens
  defp push(tokens, token), do: [token | tokens]

  defp quoted(nil), do: {"", true}
  defp quoted({text, _quoted?}), do: {text, true}

  defp append(nil, c), do: {<<c>>, false}
  defp append({text, quoted?}, c), do: {text <> <<c>>, quoted?}
end
