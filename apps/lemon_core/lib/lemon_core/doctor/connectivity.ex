defmodule LemonCore.Doctor.Connectivity do
  @moduledoc """
  Non-generating diagnostic GET requests. Responses and transport errors are never
  rendered directly: callers receive fixed failure kinds, not URLs or bodies.
  """

  alias LemonCore.Httpc

  @spec get(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(url, headers, opts \\ []) do
    timeout = Keyword.get(opts, :live_timeout_ms, 5_000)
    request_fn = Keyword.get(opts, :http_get, &Httpc.request/4)
    request_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

    case request_fn.(
           :get,
           {to_charlist(url), request_headers},
           [ssl: ssl, timeout: timeout, connect_timeout: timeout, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        {:ok, %{http_status: status, body: body}}

      {:ok, {{_, status, _}, _, _}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:timeout, _}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end
end
