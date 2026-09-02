defmodule LemonBrowser.CamofoxSession do
  @moduledoc "Exact-session-scoped adapter for the Camofox REST browser server."

  use GenServer

  alias LemonBrowser.RoutePolicy
  alias LemonBrowser.SessionProviders.Helpers

  @registry LemonBrowser.CamofoxSessionRegistry
  @supervisor LemonBrowser.CamofoxSessionSupervisor
  @default_idle_timeout_ms 300_000

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def available?(opts \\ []) do
    not is_nil(resolve_base_url(opts))
  end

  def request(method, args, timeout_ms, opts) do
    with {:ok, scope} <- exact_scope(opts),
         {:ok, pid} <- ensure_started(scope, opts) do
      GenServer.call(pid, {:request, method, args, timeout_ms}, timeout_ms + 5_000)
    end
  end

  def status do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_scope, pid} ->
      try do
        GenServer.call(pid, :status, 1_000)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    scope = Keyword.fetch!(opts, :scope)
    config = resolve_config(opts)
    idle_timeout_ms = normalize_idle(Keyword.get(opts, :idle_timeout_ms))

    {:ok,
     %{
       scope: scope,
       config: config,
       user_id: config.user_id || "lemon_#{hash(scope.session_id)}",
       session_key: config.session_key || "session_#{hash(scope.session_id)}",
       tab_id: nil,
       current_url: nil,
       idle_timeout_ms: idle_timeout_ms,
       idle_timer: schedule_idle(idle_timeout_ms),
       request_count: 0,
       last_error: nil,
       last_used_at: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:request, method, args, timeout_ms}, _from, state) do
    state = reset_idle(state)

    case dispatch(method, args, timeout_ms, state) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, touch(state, nil)}

      {:error, reason, state} ->
        {:reply, {:error, reason}, touch(state, safe_reason(reason))}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp dispatch("browser.navigate", %{"url" => url}, timeout, state) do
    with :ok <- guard_url(url, state),
         {:ok, state} <- ensure_tab(state, url, timeout),
         {:ok, snapshot} <- snapshot(state, timeout) do
      result =
        %{
          "url" => Map.get(snapshot, "url") || url,
          "title" => Map.get(snapshot, "title"),
          "snapshot" => Map.get(snapshot, "snapshot", ""),
          "elementCount" => Map.get(snapshot, "refsCount", 0)
        }

      {:ok, result, %{state | current_url: result["url"]}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch("browser.tabs", _args, timeout, state) do
    case get(state, "/tabs", [userId: state.user_id], timeout) do
      {:ok, body} ->
        tabs =
          body
          |> Map.get("tabs", [])
          |> Enum.map(fn tab ->
            id = Map.get(tab, "tabId") || Map.get(tab, "id")

            %{
              "targetId" => id,
              "url" => Map.get(tab, "url"),
              "title" => Map.get(tab, "title"),
              "active" => id == state.tab_id
            }
          end)

        {:ok, %{"tabs" => tabs, "activeTargetId" => state.tab_id}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp dispatch("browser.tabOpen", args, timeout, state) do
    url = Map.get(args, "url", "about:blank")

    case create_tab(state, url, timeout) do
      {:ok, tab_id} ->
        {:ok, %{"targetId" => tab_id, "url" => url, "active" => true},
         %{state | tab_id: tab_id, current_url: url}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp dispatch("browser.tabActivate", %{"targetId" => target_id}, timeout, state) do
    case get(state, "/tabs", [userId: state.user_id], timeout) do
      {:ok, %{"tabs" => tabs}} when is_list(tabs) ->
        case Enum.find(tabs, fn tab -> (tab["tabId"] || tab["id"]) == target_id end) do
          nil ->
            {:error, {:stale_browser_target, target_id}, state}

          tab ->
            next_state = %{state | tab_id: target_id, current_url: tab["url"]}

            case guard_url(tab["url"], state) do
              :ok -> {:ok, %{"targetId" => target_id, "active" => true}, next_state}
              {:error, reason} -> {:error, reason, next_state}
            end
        end

      {:ok, _body} ->
        {:error, "Camofox returned an invalid tab list", state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp dispatch("browser.snapshot", _args, timeout, state), do: snapshot_dispatch(state, timeout)

  defp dispatch("browser.getContent", _args, timeout, state),
    do: snapshot_dispatch(state, timeout)

  defp dispatch("browser.click", %{"selector" => selector}, timeout, state) do
    interact(state, "click", %{"ref" => clean_ref(selector)}, timeout, "clicked")
  end

  defp dispatch("browser.type", %{"selector" => selector, "text" => text}, timeout, state) do
    interact(
      state,
      "type",
      %{"ref" => clean_ref(selector), "text" => text},
      timeout,
      "typed"
    )
  end

  defp dispatch("browser.scroll", args, timeout, state) do
    direction = if number(args["y"] || args["deltaY"], 600) < 0, do: "up", else: "down"
    interact(state, "scroll", %{"direction" => direction}, timeout, "scrolled")
  end

  defp dispatch("browser.back", _args, timeout, state) do
    interact(state, "back", %{}, timeout, "navigated")
  end

  defp dispatch("browser.press", %{"key" => key}, timeout, state) do
    interact(state, "press", %{"key" => key}, timeout, "pressed")
  end

  defp dispatch("browser.screenshot", _args, timeout, state) do
    with :ok <- require_tab(state),
         :ok <- guard_current_page(state),
         {:ok, response} <- get_raw(state, "/tabs/#{state.tab_id}/screenshot", timeout) do
      content_type = header(response, "content-type") || "image/png"
      {:ok, %{"contentType" => content_type, "base64" => Base.encode64(response.body)}, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch("browser.events", _args, _timeout, state) do
    {:ok,
     %{
       "events" => [],
       "count" => 0,
       "note" => "Camofox REST does not expose browser console or page event streams."
     }, state}
  end

  defp dispatch("browser.clearState", _args, _timeout, state) do
    cleanup(state)
    {:ok, %{"cleared" => true}, %{state | tab_id: nil, current_url: nil}}
  end

  defp dispatch(method, _args, _timeout, state) do
    {:error, {:unsupported_camofox_method, method}, state}
  end

  defp snapshot_dispatch(state, timeout) do
    case snapshot(state, timeout) do
      {:ok, body} ->
        {:ok,
         %{
           "url" => body["url"] || state.current_url,
           "title" => body["title"],
           "snapshot" => body["snapshot"] || "",
           "text" => body["snapshot"] || "",
           "elementCount" => body["refsCount"] || 0
         }, %{state | current_url: body["url"] || state.current_url}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp snapshot(state, timeout) do
    with :ok <- require_tab(state),
         :ok <- guard_current_page(state),
         {:ok, body} <-
           get(state, "/tabs/#{state.tab_id}/snapshot", [userId: state.user_id], timeout),
         :ok <- guard_url(body["url"], state) do
      {:ok, body}
    end
  end

  defp interact(state, action, body, timeout, result_key) do
    with :ok <- require_tab(state),
         :ok <- guard_current_page(state),
         {:ok, result} <-
           post(
             state,
             "/tabs/#{state.tab_id}/#{action}",
             Map.put(body, "userId", state.user_id),
             timeout
           ) do
      next_state = %{state | current_url: result["url"] || state.current_url}

      case guard_url(result["url"], state) do
        :ok ->
          response =
            %{"success" => true, result_key => true}
            |> maybe_put("url", result["url"])

          {:ok, response, next_state}

        {:error, reason} ->
          {:error, reason, next_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_tab(%{tab_id: tab_id} = state, url, timeout) when is_binary(tab_id) do
    case post(
           state,
           "/tabs/#{tab_id}/navigate",
           %{"userId" => state.user_id, "url" => url},
           timeout
         ) do
      {:ok, body} -> {:ok, %{state | current_url: body["url"] || url}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_tab(state, url, timeout) do
    case create_tab(state, url, timeout) do
      {:ok, tab_id} -> {:ok, %{state | tab_id: tab_id, current_url: url}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_tab(state, url, timeout) do
    with :ok <- guard_url(url, state),
         {:ok, body} <-
           post(
             state,
             "/tabs",
             %{"userId" => state.user_id, "listItemId" => state.session_key, "url" => url},
             timeout
           ),
         tab_id when is_binary(tab_id) <- body["tabId"] do
      {:ok, tab_id}
    else
      nil -> {:error, "Camofox create-tab response omitted tabId"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(state, path, body, timeout) do
    request = state.config.http_post

    decode_response(
      request.(state.config.base_url <> path,
        headers: state.config.headers,
        json: body,
        receive_timeout: timeout
      )
    )
  end

  defp get(state, path, params, timeout) do
    request = state.config.http_get

    decode_response(
      request.(state.config.base_url <> path,
        headers: state.config.headers,
        params: params,
        receive_timeout: timeout
      )
    )
  end

  defp get_raw(state, path, timeout) do
    request = state.config.http_get

    case request.(state.config.base_url <> path,
           headers: state.config.headers,
           params: [userId: state.user_id],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      other -> Helpers.request_error("Camofox", "request", other)
    end
  end

  defp decode_response({:ok, %Req.Response{status: status} = response}) when status in 200..299,
    do: {:ok, Helpers.response_body(response)}

  defp decode_response(other), do: Helpers.request_error("Camofox", "request", other)

  defp cleanup(%{config: %{managed_persistence: true}}), do: :ok

  defp cleanup(state) do
    request = state.config.http_delete

    _ =
      request.(state.config.base_url <> "/sessions/" <> URI.encode(state.user_id),
        headers: state.config.headers,
        receive_timeout: 5_000
      )

    :ok
  catch
    _, _ -> :ok
  end

  defp guard_current_page(%{current_url: nil}), do: :ok
  defp guard_current_page(state), do: guard_url(state.current_url, state)
  defp guard_url(nil, _state), do: :ok

  defp guard_url(url, %{config: %{allow_private_network: true}}),
    do: RoutePolicy.validate_navigation(url, "auto") |> ok_only()

  defp guard_url(url, _state), do: RoutePolicy.validate_navigation(url, "public") |> ok_only()

  defp ok_only({:ok, _policy}), do: :ok
  defp ok_only({:error, reason}), do: {:error, reason}

  defp require_tab(%{tab_id: tab_id}) when is_binary(tab_id), do: :ok
  defp require_tab(_state), do: {:error, "No Camofox browser tab. Navigate first."}

  defp exact_scope(opts) do
    case normalized_opt(opts, :session_id) do
      nil -> {:error, {:missing_camofox_browser_binding, :session_id}}
      session_id -> {:ok, %{session_id: session_id, run_id: normalized_opt(opts, :run_id)}}
    end
  end

  defp ensure_started(scope, opts) do
    name = {:via, Registry, {@registry, scope}}

    case Registry.lookup(@registry, scope) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_opts = [
          key: scope,
          name: name,
          scope: scope,
          provider_config: Keyword.get(opts, :provider_config, %{}),
          http_get: Keyword.get(opts, :http_get, &Req.get/2),
          http_post: Keyword.get(opts, :http_post, &Req.post/2),
          http_delete: Keyword.get(opts, :http_delete, &Req.delete/2),
          idle_timeout_ms: Keyword.get(opts, :browser_idle_timeout_ms)
        ]

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_config(opts) do
    cfg = Keyword.get(opts, :provider_config, %{})
    api_key = Helpers.get_value(cfg, :api_key) |> Helpers.normalize()

    headers =
      [{"accept", "application/json"}, {"content-type", "application/json"}]
      |> maybe_add_auth(api_key || Helpers.secret("CAMOFOX_API_KEY"))

    %{
      base_url: resolve_base_url(opts),
      headers: headers,
      user_id: Helpers.get_value(cfg, :user_id) |> Helpers.normalize(),
      session_key: Helpers.get_value(cfg, :session_key) |> Helpers.normalize(),
      managed_persistence: Helpers.truthy(Helpers.get_value(cfg, :managed_persistence), false),
      allow_private_network:
        Helpers.truthy(Helpers.get_value(cfg, :allow_private_network), false),
      http_get: Keyword.get(opts, :http_get, &Req.get/2),
      http_post: Keyword.get(opts, :http_post, &Req.post/2),
      http_delete: Keyword.get(opts, :http_delete, &Req.delete/2)
    }
  end

  defp resolve_base_url(opts) do
    opts
    |> Keyword.get(:provider_config, %{})
    |> Helpers.get_value(:base_url, System.get_env("CAMOFOX_URL"))
    |> Helpers.normalize()
    |> case do
      nil -> nil
      value -> String.trim_trailing(value, "/")
    end
  end

  defp public_status(state) do
    %{
      provider: :camofox,
      session_id_hash: hash(state.scope.session_id),
      connected: is_binary(state.tab_id),
      tab_id_hash: hash(state.tab_id),
      managed_persistence: state.config.managed_persistence,
      allow_private_network: state.config.allow_private_network,
      request_count: state.request_count,
      last_used_at: state.last_used_at,
      last_error: state.last_error,
      idle_timeout_ms: state.idle_timeout_ms
    }
  end

  defp touch(state, error) do
    %{
      state
      | request_count: state.request_count + 1,
        last_used_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        last_error: error
    }
  end

  defp reset_idle(state) do
    _ = Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: schedule_idle(state.idle_timeout_ms)}
  end

  defp schedule_idle(timeout), do: Process.send_after(self(), :idle_timeout, timeout)
  defp normalize_idle(value) when is_integer(value) and value > 0, do: min(value, 3_600_000)
  defp normalize_idle(_), do: @default_idle_timeout_ms

  defp normalized_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) -> Helpers.normalize(value)
      _ -> nil
    end
  end

  defp clean_ref(value), do: value |> to_string() |> String.trim_leading("@")
  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp header(response, name) do
    response.headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
    |> case do
      [value | _] -> value
      value -> value
    end
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, api_key), do: headers ++ [{"authorization", "Bearer #{api_key}"}]
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 300)

  defp safe_reason(reason),
    do: reason |> inspect(limit: 8, printable_limit: 300) |> String.slice(0, 300)

  defp hash(nil), do: nil

  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
