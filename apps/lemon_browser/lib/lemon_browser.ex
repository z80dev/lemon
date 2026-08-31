defmodule LemonBrowser do
  @moduledoc """
  Backend-neutral browser execution facade.

  Callers select a backend explicitly with `:backend` or use the configured
  `:lemon_browser, :backend` value (default `:local`). Unknown or unavailable
  backends fail closed; Lemon never silently switches into a different browser
  identity or profile.
  """

  alias LemonBrowser.BackendRegistry

  @spec request(String.t(), map(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(method, args \\ %{}, timeout_ms \\ 30_000, opts \\ [])
      when is_binary(method) and is_map(args) and is_integer(timeout_ms) do
    with :ok <- authorize_method(method, args, opts),
         {:ok, backend} <- resolve_backend(opts),
         true <- backend_available?(backend, opts) do
      backend.request(method, args, timeout_ms, opts)
    else
      false -> {:error, :browser_backend_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_method("browser.cdp", args, opts) do
    cond do
      Keyword.get(opts, :developer_mode, false) != true ->
        {:error, :browser_developer_mode_required}

      args["method"] in [
        "Browser.close",
        "Target.closeTarget",
        "Browser.setDownloadBehavior",
        "Page.setDownloadBehavior"
      ] ->
        {:error, {:blocked_cdp_method, args["method"]}}

      true ->
        :ok
    end
  end

  defp authorize_method(_method, _args, _opts), do: :ok

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    case resolve_backend(opts) do
      {:ok, backend} ->
        backend.status(opts)
        |> Map.put_new(:backend, backend.id())
        |> Map.put_new(:available, backend_available?(backend, opts))

      {:error, reason} ->
        %{available: false, running: false, error: inspect(reason)}
    end
  end

  defp resolve_backend(opts) do
    id =
      Keyword.get(opts, :backend) || System.get_env("LEMON_BROWSER_BACKEND") ||
        Application.get_env(:lemon_browser, :backend, :local)

    case BackendRegistry.fetch(id) do
      {:ok, backend} -> {:ok, backend}
      :error -> {:error, {:unknown_browser_backend, id}}
    end
  end

  defp backend_available?(backend, opts) do
    if function_exported?(backend, :available?, 1),
      do: backend.available?(opts),
      else: backend.available?()
  end
end
