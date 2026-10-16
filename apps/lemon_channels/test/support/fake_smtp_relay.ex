defmodule LemonChannels.FakeSmtpRelay do
  @moduledoc """
  Throwaway SMTP relay for hermetic email delivery tests.

  A loopback TCP listener on an ephemeral port whose accepted connections are
  handled by scripted functions, letting a test play exactly the dialogue a real
  relay would speak, including the failing ones. Nothing leaves the machine.

  This module lives in `test/support` and is compiled only when
  `MIX_ENV=test`; it is never part of a release.
  """

  @doc """
  Listens on an ephemeral loopback port and serves one connection per handler,
  in order. A handler receives the accepted socket; the socket is closed when it
  returns. Returns the port and the server task to `await/1`.
  """
  @spec smtp_server((:gen_tcp.socket() -> term()) | [(:gen_tcp.socket() -> term())]) ::
          {:inet.port_number(), Task.t()}
  def smtp_server(fun) when is_function(fun, 1), do: smtp_server([fun])

  def smtp_server(funs) when is_list(funs) do
    {:ok, listen} =
      :gen_tcp.listen(0,
        mode: :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      )

    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        try do
          Enum.reduce_while(funs, :ok, fn fun, :ok ->
            case :gen_tcp.accept(listen, 5_000) do
              {:ok, socket} ->
                try do
                  fun.(socket)
                after
                  :gen_tcp.close(socket)
                end

                {:cont, :ok}

              {:error, _} ->
                {:halt, :ok}
            end
          end)
        after
          :gen_tcp.close(listen)
        end
      end)

    {port, server}
  end

  @doc """
  Speaks a well-behaved relay up to and including the message body: greeting,
  EHLO, MAIL FROM, RCPT TO and DATA are accepted, and the body is read through
  its terminating dot line. Returns the body, or `{:error, reason}` if the
  client went away first. The final reply is left to the caller, so a test can
  accept, reject or drop the connection once DATA is in.
  """
  @spec receive_message(:gen_tcp.socket()) :: binary() | {:error, term()}
  def receive_message(socket) do
    tcp_send(socket, "220 fake ESMTP")
    _ehlo = tcp_recv(socket)
    tcp_send(socket, "250 fake")
    _mail_from = tcp_recv(socket)
    tcp_send(socket, "250 ok")
    _rcpt_to = tcp_recv(socket)
    tcp_send(socket, "250 ok")
    _data = tcp_recv(socket)
    tcp_send(socket, "354 end data with <CR><LF>.<CR><LF>")
    read_body(socket, [])
  end

  @doc "Accepts a whole message: `receive_message/1` then a `250` queued reply."
  @spec accept_message(:gen_tcp.socket()) :: binary() | {:error, term()}
  def accept_message(socket) do
    body = receive_message(socket)
    tcp_send(socket, "250 2.0.0 queued as FAKE")
    body
  end

  @spec tcp_send(:gen_tcp.socket(), binary()) :: :ok | {:error, term()}
  def tcp_send(socket, line), do: :gen_tcp.send(socket, line <> "\r\n")

  @spec tcp_recv(:gen_tcp.socket()) :: binary() | {:error, term()}
  def tcp_recv(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> data
      {:error, _} = error -> error
    end
  end

  @doc """
  Waits for the relay task so a failed dialogue surfaces in the test rather than
  as a stray log line after it has moved on.
  """
  @spec await(Task.t()) :: term()
  def await(server), do: Task.await(server, 10_000)

  @doc """
  A loopback port with nothing listening: bind one, read its number, release it.
  A connect there gets ECONNREFUSED rather than hanging.
  """
  @spec closed_port() :: :inet.port_number()
  def closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp read_body(socket, acc) do
    case tcp_recv(socket) do
      ".\r\n" -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, _} = error -> error
      line -> read_body(socket, [line | acc])
    end
  end
end
