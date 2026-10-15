defmodule LemonBrowser do
  @moduledoc """
  Backend-neutral browser execution facade.

  The unified `runtime.tools.browser.provider` setting selects a browser surface.
  Auto resolution is read-only; explicit providers fail closed. Internal callers
  may still select a backend with `:backend` for exact-session routing.
  """

  alias LemonBrowser.BackendRegistry

  @spec request(String.t(), map(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(method, args \\ %{}, timeout_ms \\ 30_000, opts \\ [])
      when is_binary(method) and is_map(args) and is_integer(timeout_ms) do
    with :ok <- authorize_method(method, args, opts),
         {:ok, backend, opts} <- resolve_backend(opts),
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
    resolution =
      Keyword.get_lazy(opts, :provider_resolution, &LemonCore.BrowserProvider.resolve/0)

    status =
      case resolve_backend(Keyword.put(opts, :provider_resolution, resolution)) do
        {:ok, backend, backend_opts} ->
          backend.status(backend_opts)
          |> Map.put_new(:backend, backend.id())
          |> Map.put_new(:available, backend_available?(backend, backend_opts))

        {:error, _reason} ->
          %{available: resolution.provider == "lcu", running: false}
      end

    Map.put(status, :provider_resolution, resolution)
  end

  defp resolve_backend(opts) do
    case Keyword.get(opts, :backend) do
      nil ->
        resolution =
          Keyword.get_lazy(opts, :provider_resolution, &LemonCore.BrowserProvider.resolve/0)

        case resolution.provider do
          nil ->
            {:error, resolution.reason}

          "lcu" ->
            {:error, "Browser provider is lcu; use the cua_js computer-use Chrome surface."}

          provider ->
            id = if provider in ["local", "relay", "cdp"], do: "local", else: provider
            fetch_backend(id, Keyword.put(opts, :browser_provider, provider))
        end

      id ->
        fetch_backend(id, opts)
    end
  end

  defp fetch_backend(id, opts) do
    case BackendRegistry.fetch(id) do
      {:ok, backend} -> {:ok, backend, opts}
      :error -> {:error, {:unknown_browser_backend, id}}
    end
  end

  defp backend_available?(backend, opts) do
    if function_exported?(backend, :available?, 1),
      do: backend.available?(opts),
      else: backend.available?()
  end
end
