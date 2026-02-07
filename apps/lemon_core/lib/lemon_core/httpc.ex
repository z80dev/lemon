defmodule LemonCore.Httpc do
  @moduledoc """
  Thin wrapper around Erlang's `:httpc`.

  Goals:
  - Centralize `:inets`/`:ssl` startup for call sites that want to use built-in HTTP.
  - Keep call sites consistent while still returning `:httpc`'s native return values.

  This wrapper intentionally does not attempt to normalize response formats.
  """

  @type method :: :get | :post | :put | :patch | :delete | :head | atom()
  @type request :: term()
  @type http_opts :: keyword()
  @type opts :: keyword()

  @doc """
  Ensure `:inets` and `:ssl` are started.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    _ = :inets.start()
    _ = :ssl.start()
    :ok
  end

  @doc """
  Call `:httpc.request/4` after ensuring OTP apps are started.
  """
  @spec request(method(), request(), http_opts(), opts()) :: term()
  def request(method, request, http_opts \\ [], opts \\ []) do
    :ok = ensure_started()
    :httpc.request(method, request, http_opts, opts)
  end
end

