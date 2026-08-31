defmodule LemonBrowser.Backends.Hybrid do
  @moduledoc """
  Hybrid browser backend that keeps local/private targets local and sends only
  public network targets to an explicitly configured hosted backend.
  """

  @behaviour LemonBrowser.Backend

  alias LemonBrowser.{BackendRegistry, HybridRouter, RoutePolicy}

  @impl true
  def id, do: :hybrid

  @impl true
  def available?, do: false

  @impl true
  def available?(opts) do
    with {:ok, local} <- backend(opts, :hybrid_local_backend, :local),
         {:ok, public} <- backend(opts, :hybrid_public_backend, nil),
         true <- local.id() != :hybrid and public.id() != :hybrid do
      available?(local, opts) and available?(public, opts)
    else
      _ -> false
    end
  end

  @impl true
  def request(method, args, timeout_ms, opts) do
    with {:ok, scope} <- exact_scope(opts),
         {:ok, selected} <- select_backend(scope, method, args, opts),
         true <- available?(selected, opts),
         result <- selected.request(method, args, timeout_ms, opts) do
      maybe_clear_route(result, method, scope)
    else
      false -> {:error, :hybrid_browser_route_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def status(opts) do
    %{
      available: available?(opts),
      local_backend: safe_backend_id(opts, :hybrid_local_backend, :local),
      public_backend: safe_backend_id(opts, :hybrid_public_backend, nil),
      routing: HybridRouter.status()
    }
  end

  defp select_backend(scope, method, args, opts)
       when method in ["browser.navigate", "browser.tabOpen"] do
    url = args["url"] || "about:blank"

    with {:ok, policy} <- RoutePolicy.validate_navigation(url, "auto"),
         {:ok, selected} <- backend_for_route(policy.effective_route, opts),
         :ok <- HybridRouter.put(scope, selected.id()) do
      {:ok, selected}
    end
  end

  defp select_backend(scope, _method, _args, _opts) do
    case HybridRouter.fetch(scope) do
      {:ok, backend_id} ->
        case BackendRegistry.fetch(backend_id) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, {:hybrid_browser_backend_disappeared, backend_id}}
        end

      :error ->
        {:error, :hybrid_browser_navigation_required}
    end
  end

  defp backend_for_route("local", opts), do: backend(opts, :hybrid_local_backend, :local)
  defp backend_for_route("public", opts), do: backend(opts, :hybrid_public_backend, nil)

  defp backend(opts, key, default) do
    env_name =
      case key do
        :hybrid_local_backend -> "LEMON_BROWSER_HYBRID_LOCAL_BACKEND"
        :hybrid_public_backend -> "LEMON_BROWSER_HYBRID_PUBLIC_BACKEND"
      end

    case Keyword.get(opts, key) || System.get_env(env_name) || default do
      nil ->
        {:error, {:missing_hybrid_browser_backend, key}}

      :hybrid ->
        {:error, :recursive_hybrid_browser_backend}

      "hybrid" ->
        {:error, :recursive_hybrid_browser_backend}

      id ->
        case BackendRegistry.fetch(id) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, {:unknown_hybrid_browser_backend, id}}
        end
    end
  end

  defp exact_scope(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, %{session_id: session_id, run_id: Keyword.get(opts, :run_id)}}

      _ ->
        {:error, {:missing_hybrid_browser_binding, :session_id}}
    end
  end

  defp available?(module, opts) do
    if function_exported?(module, :available?, 1),
      do: module.available?(opts),
      else: module.available?()
  end

  defp maybe_clear_route({:ok, _result} = result, "browser.clearState", scope) do
    HybridRouter.delete(scope)
    result
  end

  defp maybe_clear_route(result, _method, _scope), do: result

  defp safe_backend_id(opts, key, default) do
    env_name =
      case key do
        :hybrid_local_backend -> "LEMON_BROWSER_HYBRID_LOCAL_BACKEND"
        :hybrid_public_backend -> "LEMON_BROWSER_HYBRID_PUBLIC_BACKEND"
      end

    case Keyword.get(opts, key) || System.get_env(env_name) || default do
      value when is_atom(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
