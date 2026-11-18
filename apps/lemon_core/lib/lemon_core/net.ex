defmodule LemonCore.Net do
  @moduledoc """
  Outbound network option builders shared by every Lemon client.

  `web_socket_options/2` is the only supported way to build `WebSockex`
  connection options. WebSockex defaults to `verify: :verify_none`; this builder
  always replaces that with peer verification against the OS trust store,
  hostname checking and SNI for `wss:` URLs.

  Plaintext `ws:` is allowed only to a literal loopback IP. The bare name
  `localhost` is pinned to `127.0.0.1` instead of being resolved, so DNS cannot
  redirect a plaintext connection off the host; `*.localhost` and every other
  name are refused. The explicit `allow_insecure_ws: true` override (used only
  for the execution node's documented `--allow-insecure-controller` flag)
  permits plaintext to other hosts; it never affects `wss:` verification.

  OTP caches the OS trust store on first use: restart the BEAM after changing
  system CA roots.
  """

  @tls_override_keys [:insecure, :cacerts, :ssl_options, :allow_insecure_ws, :extra_cacerts]

  @doc """
  Validates a WebSocket URL and returns the URL to connect to plus `WebSockex`
  options for it.

  The returned URL differs from the input only when a plaintext `localhost`
  host is pinned to `127.0.0.1`. Caller options are kept except TLS settings,
  which cannot be overridden. `extra_cacerts:` (DER certificates) is appended to
  the OS trust store; it is an internal option, not user configuration.
  """
  @spec web_socket_options(term(), keyword()) ::
          {:ok, String.t(), keyword()}
          | {:error, :invalid_web_socket_url | :insecure_web_socket_url}
  def web_socket_options(url, opts \\ []) when is_list(opts) do
    allow_insecure? = Keyword.get(opts, :allow_insecure_ws, false) == true
    extra_cacerts = Keyword.get(opts, :extra_cacerts, [])
    base = Keyword.drop(opts, @tls_override_keys) ++ [insecure: false]

    case parse(url) do
      {:ok, %URI{scheme: "wss", host: host} = uri} ->
        {:ok, URI.to_string(uri),
         Keyword.put(base, :ssl_options, tls_options(host, extra_cacerts))}

      {:ok, %URI{scheme: "ws", host: host} = uri} ->
        cond do
          LemonCore.LoopbackListener.literal_loopback?(host) ->
            {:ok, URI.to_string(uri), base}

          String.downcase(host) == "localhost" ->
            {:ok, URI.to_string(%{uri | host: "127.0.0.1"}), base}

          allow_insecure? ->
            {:ok, URI.to_string(uri), base}

          true ->
            {:error, :insecure_web_socket_url}
        end

      :error ->
        {:error, :invalid_web_socket_url}
    end
  end

  defp parse(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp parse(_url), do: :error

  defp tls_options(host, extra_cacerts) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.to_charlist()

    sni =
      case :inet.parse_address(host) do
        {:ok, _ip} -> []
        _ -> [server_name_indication: host]
      end

    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get() ++ Enum.filter(extra_cacerts, &is_binary/1),
      depth: 10,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ] ++ sni
  end
end
