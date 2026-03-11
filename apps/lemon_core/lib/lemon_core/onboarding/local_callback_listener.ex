defmodule LemonCore.Onboarding.LocalCallbackListener do
  @moduledoc false
  @unsupported_bind_reasons [:eafnosupport, :eaddrnotavail, :enotsup, :eprotonosupport]

  defstruct [
    :pid,
    :ref,
    :listen_sockets,
    :host,
    :port,
    :path,
    :redirect_uri
  ]

  @type t :: %__MODULE__{
          pid: pid(),
          ref: reference(),
          listen_sockets: [port()],
          host: String.t(),
          port: pos_integer(),
          path: String.t(),
          redirect_uri: String.t()
        }

  @spec start(String.t()) :: {:ok, t()} | {:error, term()}
  def start(redirect_uri) when is_binary(redirect_uri) do
    owner = self()

    with {:ok, info} <- parse_local_redirect_uri(redirect_uri),
         {:ok, listen_sockets} <- listen(info.host, info.port) do
      ref = make_ref()

      pid =
        spawn(fn ->
          run_listener(owner, ref, listen_sockets, info)
        end)

      {:ok,
       %__MODULE__{
         pid: pid,
         ref: ref,
         listen_sockets: listen_sockets,
         host: info.host,
         port: info.port,
         path: info.path,
         redirect_uri: redirect_uri
       }}
    end
  end

  def start(_), do: {:error, :invalid_redirect_uri}

  @spec wait(t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def wait(%__MODULE__{ref: ref} = listener, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    receive do
      {^ref, result} ->
        result
    after
      timeout_ms ->
        stop(listener)
        {:error, :timeout}
    end
  end

  def wait(%__MODULE__{} = listener, _timeout_ms) do
    stop(listener)
    {:error, :timeout}
  end

  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%__MODULE__{listen_sockets: listen_sockets, pid: pid}) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    close_sockets(listen_sockets)
    :ok
  end

  @spec local_redirect_uri?(String.t()) :: boolean()
  def local_redirect_uri?(redirect_uri) when is_binary(redirect_uri) do
    match?({:ok, _}, parse_local_redirect_uri(redirect_uri))
  end

  def local_redirect_uri?(_), do: false

  defp parse_local_redirect_uri(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: host, port: port} = uri
      when host in ["localhost", "127.0.0.1"] and is_integer(port) and port > 0 ->
        {:ok,
         %{
           scheme: "http",
           host: host,
           port: port,
           path: normalize_path(uri.path)
         }}

      %URI{scheme: scheme} when scheme not in [nil, "http"] ->
        {:error, :unsupported_scheme}

      _ ->
        {:error, :unsupported_redirect_uri}
    end
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path

  defp listen("127.0.0.1", port) do
    case listen_ipv4(port) do
      {:ok, socket} -> {:ok, [socket]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp listen("localhost", port) do
    ipv4_result = listen_ipv4(port)
    ipv6_result = listen_ipv6(port)

    case {ipv4_result, ipv6_result} do
      {{:ok, ipv4_socket}, {:ok, ipv6_socket}} ->
        {:ok, [ipv4_socket, ipv6_socket]}

      {{:ok, ipv4_socket}, {:error, reason}} when reason in @unsupported_bind_reasons ->
        {:ok, [ipv4_socket]}

      {{:error, reason}, {:ok, ipv6_socket}} when reason in @unsupported_bind_reasons ->
        {:ok, [ipv6_socket]}

      {{:ok, ipv4_socket}, {:error, reason}} ->
        close_socket(ipv4_socket)
        {:error, reason}

      {{:error, reason}, {:ok, ipv6_socket}} ->
        close_socket(ipv6_socket)
        {:error, reason}

      {{:error, reason}, {:error, _other_reason}} ->
        {:error, reason}
    end
  end

  defp listen_ipv4(port) do
    :gen_tcp.listen(port, [
      :binary,
      {:packet, :raw},
      {:active, false},
      {:reuseaddr, true},
      {:ip, {127, 0, 0, 1}}
    ])
  end

  defp listen_ipv6(port) do
    :gen_tcp.listen(port, [
      :binary,
      {:packet, :raw},
      {:active, false},
      {:reuseaddr, true},
      :inet6,
      {:ip, {0, 0, 0, 0, 0, 0, 0, 1}}
    ])
  end

  defp run_listener(owner, ref, listen_sockets, info) do
    manager = self()

    Enum.each(listen_sockets, fn listen_socket ->
      spawn_link(fn ->
        send(manager, {:accept_result, accept_once(listen_socket, info)})
      end)
    end)

    await_accept_result(owner, ref, listen_sockets, length(listen_sockets))
  end

  defp await_accept_result(owner, ref, listen_sockets, pending) when pending > 0 do
    receive do
      {:accept_result, {:ok, callback_url}} ->
        close_sockets(listen_sockets)
        send(owner, {ref, {:ok, callback_url}})

      {:accept_result, {:error, reason}} when pending == 1 ->
        close_sockets(listen_sockets)
        send(owner, {ref, {:error, reason}})

      {:accept_result, {:error, _reason}} ->
        await_accept_result(owner, ref, listen_sockets, pending - 1)
    end
  end

  defp accept_once(listen_socket, info) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        try do
          handle_request(socket, info)
        after
          close_socket(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_request(socket, info) do
    with {:ok, request} <- recv_request(socket, ""),
         {:ok, request_target} <- parse_request_target(request),
         {:ok, callback_url} <- build_callback_url(info, request_target),
         :ok <- send_response(socket, 200, success_page()) do
      {:ok, callback_url}
    else
      {:error, :unexpected_path} = error ->
        _ = send_response(socket, 404, error_page("Unexpected callback path."))
        error

      {:error, _reason} = error ->
        _ =
          send_response(
            socket,
            400,
            error_page("Authentication callback could not be processed.")
          )

        error
    end
  end

  defp recv_request(_socket, acc) when byte_size(acc) > 16_384, do: {:error, :request_too_large}

  defp recv_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        request = acc <> chunk

        if String.contains?(request, "\r\n\r\n") do
          {:ok, request}
        else
          recv_request(socket, request)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_request_target(request) when is_binary(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line | _] ->
        case String.split(request_line, " ", parts: 3) do
          [_method, request_target, _version]
          when is_binary(request_target) and request_target != "" ->
            {:ok, request_target}

          _ ->
            {:error, :invalid_request_line}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp build_callback_url(info, request_target) when is_binary(request_target) do
    %URI{path: path, query: query} = URI.parse(request_target)

    if normalize_path(path) == info.path do
      {:ok,
       %URI{
         scheme: info.scheme,
         host: info.host,
         port: info.port,
         path: normalize_path(path),
         query: query
       }
       |> URI.to_string()}
    else
      {:error, :unexpected_path}
    end
  end

  defp send_response(socket, status, body) when is_integer(status) and is_binary(body) do
    response =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason_phrase(status),
        "\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\nconnection: close\r\ncache-control: no-store\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    case :gen_tcp.send(socket, response) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp success_page do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Lemon Sign-In Complete</title>
      </head>
      <body style="font-family: sans-serif; max-width: 36rem; margin: 3rem auto; line-height: 1.5;">
        <h1>Sign-in complete</h1>
        <p>You can return to Lemon. This browser window can be closed.</p>
      </body>
    </html>
    """
  end

  defp error_page(message) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Lemon Sign-In Error</title>
      </head>
      <body style="font-family: sans-serif; max-width: 36rem; margin: 3rem auto; line-height: 1.5;">
        <h1>Sign-in could not be completed</h1>
        <p>#{html_escape(message)}</p>
        <p>You can return to Lemon and continue manually if needed.</p>
      </body>
    </html>
    """
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(_), do: "OK"

  defp close_sockets(sockets) when is_list(sockets) do
    Enum.each(sockets, &close_socket/1)
  end

  defp close_socket(nil), do: :ok

  defp close_socket(socket) do
    :gen_tcp.close(socket)
  catch
    :exit, _ -> :ok
  end
end
