defmodule LemonBrowser.ComputerUseSession do
  @moduledoc """
  Exact-session computer-use adapter with a cua-driver-compatible action surface.

  Input delivery defaults to background mode. Results are never replayed after
  a timeout or transport error because the effect may already have occurred.
  """

  use GenServer

  alias LemonBrowser.CuaDriverCLI

  @registry LemonBrowser.ComputerUseSessionRegistry
  @supervisor LemonBrowser.ComputerUseSessionSupervisor
  @default_timeout_ms 30_000
  @max_wait_seconds 30
  @input_actions ~w(click double_click right_click middle_click drag scroll type key set_value)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :scope)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def request(params, timeout_ms \\ @default_timeout_ms, opts \\ []) when is_map(params) do
    with {:ok, scope} <- exact_scope(opts),
         {:ok, pid} <- ensure_started(scope, opts) do
      GenServer.call(pid, {:request, params, timeout_ms}, timeout_ms + 5_000)
    end
  end

  def status do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_scope, pid} -> GenServer.call(pid, :status, 1_000) end)
  end

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)

    runner =
      Keyword.get(opts, :computer_use_runner) ||
        fn tool, args, timeout ->
          CuaDriverCLI.call(tool, args, timeout,
            driver_path: Keyword.get(opts, :cua_driver_path),
            socket_path: Keyword.get(opts, :cua_socket_path)
          )
        end

    {:ok,
     %{
       scope: scope,
       public_session_id: "lemon-#{hash(scope.session_id)}",
       runner: runner,
       active_target: nil,
       request_count: 0,
       last_error: nil,
       last_used_at: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       session_id_hash: hash(state.scope.session_id),
       active_target: safe_target(state.active_target),
       request_count: state.request_count,
       last_error: state.last_error,
       last_used_at: state.last_used_at
     }, state}
  end

  def handle_call({:request, params, timeout_ms}, _from, state) do
    action = params["action"] || params[:action]

    case dispatch(action, stringify_keys(params), normalize_timeout(timeout_ms), state) do
      {:ok, result, state} -> {:reply, {:ok, result}, touch(state, nil)}
      {:error, reason, state} -> {:reply, {:error, reason}, touch(state, reason)}
    end
  end

  defp dispatch("capture", params, timeout, state) do
    mode = params["mode"] || "som"

    with :ok <- validate_mode(mode),
         {:ok, target, state} <- resolve_capture_target(params, timeout, state),
         {:ok, raw} <- capture_target(target, mode, timeout, state) do
      result =
        raw
        |> sanitize_driver_result()
        |> Map.merge(%{
          "action" => "capture",
          "mode" => mode,
          "target" => safe_target(target),
          "verdict" => verdict(raw, "capture")
        })

      {:ok, result, %{state | active_target: target}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch("list_apps", _params, timeout, state) do
    call(state, "list_apps", %{}, timeout)
    |> result_tuple("list_apps", state)
  end

  defp dispatch("list_windows", _params, timeout, state) do
    call(state, "list_windows", %{}, timeout)
    |> result_tuple("list_windows", state)
  end

  defp dispatch("focus_app", params, timeout, state) do
    with app when is_binary(app) and app != "" <- params["app"],
         {:ok, target} <- find_target(app, timeout, state),
         {:ok, raw} <- maybe_raise_target(target, params["raise_window"] == true, timeout, state) do
      result =
        raw
        |> sanitize_driver_result()
        |> Map.merge(%{
          "action" => "focus_app",
          "target" => safe_target(target),
          "raised" => params["raise_window"] == true,
          "verdict" => verdict(raw, "focus_app")
        })

      {:ok, result, %{state | active_target: target}}
    else
      nil -> {:error, "focus_app requires app", state}
      "" -> {:error, "focus_app requires app", state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch("wait", params, _timeout, state) do
    seconds = params["seconds"] || 1

    if is_number(seconds) and seconds >= 0 do
      bounded = min(seconds, @max_wait_seconds)
      Process.sleep(round(bounded * 1_000))
      {:ok, %{"action" => "wait", "seconds" => bounded}, state}
    else
      {:error, "wait seconds must be a non-negative number", state}
    end
  end

  defp dispatch(action, params, timeout, state) when action in @input_actions do
    with :ok <- require_target(state),
         :ok <- validate_delivery(params),
         {:ok, tool, arguments} <- input_call(action, params, state.active_target),
         {:ok, raw} <- call(state, tool, arguments, timeout),
         {:ok, capture} <- maybe_capture_after(params, timeout, state) do
      result =
        raw
        |> sanitize_driver_result()
        |> Map.merge(%{
          "action" => action,
          "deliveryMode" => params["delivery_mode"] || "background",
          "target" => safe_target(state.active_target),
          "verdict" => verdict(raw, action)
        })
        |> maybe_put("capture", capture)

      {:ok, result, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch(nil, _params, _timeout, state),
    do: {:error, "computer_use requires action", state}

  defp dispatch(action, _params, _timeout, state),
    do: {:error, {:unsupported_computer_use_action, action}, state}

  defp resolve_capture_target(%{"app" => app} = params, _timeout, state)
       when app in ["screen", "fullscreen", "full screen", "all"] do
    if params["pid"] || params["window_id"] do
      {:error, "full-screen capture cannot be combined with pid/window_id"}
    else
      {:ok, %{kind: :desktop, app: "screen"}, state}
    end
  end

  defp resolve_capture_target(params, timeout, state) do
    pid = positive_integer(params["pid"])
    window_id = positive_integer(params["window_id"])

    cond do
      pid && window_id ->
        {:ok, %{kind: :window, pid: pid, window_id: window_id, app: params["app"], title: nil},
         state}

      pid || window_id ->
        {:error, "capture targeting requires both positive pid and window_id"}

      is_binary(params["app"]) ->
        case find_target(params["app"], timeout, state) do
          {:ok, target} -> {:ok, target, state}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case frontmost_target(timeout, state) do
          {:ok, target} -> {:ok, target, state}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp capture_target(%{kind: :desktop}, mode, timeout, state) do
    call(state, "get_desktop_state", %{"mode" => mode}, timeout)
  end

  defp capture_target(target, mode, timeout, state) do
    call(
      state,
      "get_window_state",
      %{
        "pid" => target.pid,
        "window_id" => target.window_id,
        "mode" => mode
      },
      timeout
    )
  end

  defp input_call(action, params, target) do
    base =
      %{"pid" => target.pid, "window_id" => target.window_id}
      |> maybe_put("delivery_mode", foreground_only(params))

    case action do
      action when action in ~w(click double_click right_click middle_click) ->
        click_call(action, params, base)

      "drag" ->
        drag_call(params, base)

      "scroll" ->
        direction = params["direction"] || "down"
        amount = params["amount"] || 3

        if direction in ~w(up down left right) and is_integer(amount) do
          {:ok, "scroll",
           base
           |> Map.put("direction", direction)
           |> Map.put("amount", max(1, min(amount, 50)))
           |> add_pointer_target(params)}
        else
          {:error, "scroll requires a valid direction and integer amount"}
        end

      "type" ->
        required_text(params, "text", fn text ->
          {:ok, "type_text", Map.put(base, "text", text)}
        end)

      "key" ->
        required_text(params, "keys", fn keys -> key_call(keys, base) end)

      "set_value" ->
        with element when is_integer(element) and element > 0 <- params["element"],
             value when is_binary(value) <- params["value"] do
          {:ok, "set_value", Map.merge(base, %{"element_index" => element, "value" => value})}
        else
          _ -> {:error, "set_value requires element and value"}
        end
    end
  end

  defp click_call(action, params, base) do
    tool = if action == "double_click", do: "double_click", else: "click"

    button =
      case action do
        "right_click" -> "right"
        "middle_click" -> "middle"
        _ -> params["button"] || "left"
      end

    args = base |> Map.put("button", button) |> add_pointer_target(params)

    if Map.has_key?(args, "element_index") or
         (Map.has_key?(args, "x") and Map.has_key?(args, "y")) do
      {:ok, tool, add_modifiers(args, params)}
    else
      {:error, "#{action} requires element or coordinate [x, y]"}
    end
  end

  defp drag_call(params, base) do
    args =
      cond do
        positive_integer(params["from_element"]) && positive_integer(params["to_element"]) ->
          Map.merge(base, %{
            "from_element" => positive_integer(params["from_element"]),
            "to_element" => positive_integer(params["to_element"])
          })

        coordinate(params["from_coordinate"]) && coordinate(params["to_coordinate"]) ->
          [from_x, from_y] = coordinate(params["from_coordinate"])
          [to_x, to_y] = coordinate(params["to_coordinate"])

          Map.merge(base, %{
            "from_x" => from_x,
            "from_y" => from_y,
            "to_x" => to_x,
            "to_y" => to_y
          })

        true ->
          nil
      end

    if args,
      do: {:ok, "drag", add_modifiers(args, params)},
      else: {:error, "drag requires endpoints"}
  end

  defp key_call(keys, base) do
    parts = keys |> String.downcase() |> String.split("+", trim: true)

    modifiers =
      Enum.filter(parts, &(&1 in ~w(cmd ctrl alt option shift fn win windows super meta)))

    keys_only = parts -- modifiers

    case keys_only do
      [key] when modifiers == [] -> {:ok, "press_key", Map.put(base, "key", key)}
      [key] -> {:ok, "hotkey", Map.put(base, "keys", modifiers ++ [key])}
      _ -> {:error, "key requires one key with optional modifiers"}
    end
  end

  defp maybe_capture_after(%{"capture_after" => true}, timeout, state) do
    case capture_target(state.active_target, "som", timeout, state) do
      {:ok, raw} -> {:ok, sanitize_driver_result(raw)}
      {:error, reason} -> {:error, {:capture_after_failed, reason}}
    end
  end

  defp maybe_capture_after(_params, _timeout, _state), do: {:ok, nil}

  defp maybe_raise_target(_target, false, _timeout, _state),
    do: {:ok, %{"structuredContent" => %{"verified" => true, "effect" => "target_selected"}}}

  defp maybe_raise_target(target, true, timeout, state) do
    call(
      state,
      "bring_to_front",
      %{"pid" => target.pid, "window_id" => target.window_id},
      timeout
    )
  end

  defp find_target(app, timeout, state) do
    app_down = String.downcase(app)

    with {:ok, windows} <- load_windows(timeout, state),
         target when not is_nil(target) <-
           Enum.find(windows, fn window ->
             String.contains?(String.downcase(window.app <> " " <> window.title), app_down)
           end) do
      {:ok, target}
    else
      nil -> {:error, {:computer_use_app_not_found, app}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp frontmost_target(timeout, state) do
    with {:ok, windows} <- load_windows(timeout, state),
         target when not is_nil(target) <- Enum.max_by(windows, & &1.z_index, fn -> nil end) do
      {:ok, target}
    else
      nil -> {:error, :computer_use_no_windows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_windows(timeout, state) do
    with {:ok, raw} <- call(state, "list_windows", %{}, timeout) do
      windows =
        raw
        |> extract_collection("windows")
        |> Enum.map(&normalize_window/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(& &1.off_screen)

      {:ok, windows}
    end
  end

  defp normalize_window(window) when is_map(window) do
    pid = positive_integer(window["pid"] || window[:pid])
    window_id = positive_integer(window["window_id"] || window[:window_id])

    if pid && window_id do
      %{
        kind: :window,
        pid: pid,
        window_id: window_id,
        app: to_string(window["app_name"] || window[:app_name] || ""),
        title: to_string(window["title"] || window[:title] || ""),
        z_index: window["z_index"] || window[:z_index] || 0,
        off_screen: Map.get(window, "is_on_screen", Map.get(window, :is_on_screen)) == false
      }
    end
  end

  defp normalize_window(_), do: nil

  defp call(state, tool, arguments, timeout) do
    arguments = Map.put(arguments, "session", state.public_session_id)
    state.runner.(tool, arguments, timeout)
  rescue
    error -> {:error, {:computer_use_transport_error, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:computer_use_transport_error, kind, reason}}
  end

  defp result_tuple({:ok, raw}, action, state) do
    {:ok,
     raw
     |> sanitize_driver_result()
     |> Map.merge(%{"action" => action, "verdict" => verdict(raw, action)}), state}
  end

  defp result_tuple({:error, reason}, _action, state), do: {:error, reason, state}

  defp sanitize_driver_result(raw) when is_map(raw) do
    raw
    |> Map.drop(["session", "session_id", "socket", "authorization"])
    |> Map.take(["content", "structuredContent", "data", "images", "image_mime_types", "isError"])
  end

  defp sanitize_driver_result(_raw), do: %{}

  defp verdict(raw, action) do
    structured = raw["structuredContent"] || %{}

    %{
      "action" => action,
      "verified" => structured["verified"],
      "effect" => structured["effect"],
      "escalation" => structured["escalation"],
      "path" => structured["path"],
      "degraded" => structured["degraded"],
      "code" => structured["code"] || structured["reason_code"],
      "nextStep" => structured["next_step"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp extract_collection(raw, key) do
    structured = raw["structuredContent"] || %{}
    data = raw["data"] || %{}

    cond do
      is_list(structured[key]) -> structured[key]
      is_map(data) and is_list(data[key]) -> data[key]
      is_list(raw[key]) -> raw[key]
      true -> []
    end
  end

  defp validate_mode(mode) when mode in ~w(som vision ax), do: :ok
  defp validate_mode(_), do: {:error, "capture mode must be som, vision, or ax"}

  defp validate_delivery(%{"bring_to_front" => true, "delivery_mode" => mode})
       when mode != "foreground",
       do: {:error, "bring_to_front requires delivery_mode=foreground"}

  defp validate_delivery(%{"delivery_mode" => mode})
       when mode not in [nil, "background", "foreground"],
       do: {:error, "delivery_mode must be background or foreground"}

  defp validate_delivery(_), do: :ok

  defp foreground_only(%{"delivery_mode" => "foreground"}), do: "foreground"
  defp foreground_only(_), do: nil

  defp require_target(%{active_target: %{kind: :window}}), do: :ok
  defp require_target(_), do: {:error, "Capture or focus an app window before input actions"}

  defp add_pointer_target(args, %{"element" => element}) when is_integer(element) and element > 0,
    do: Map.put(args, "element_index", element)

  defp add_pointer_target(args, %{"coordinate" => [x, y]}) when is_integer(x) and is_integer(y),
    do: Map.merge(args, %{"x" => x, "y" => y})

  defp add_pointer_target(args, _params), do: args

  defp add_modifiers(args, %{"modifiers" => modifiers}) when is_list(modifiers),
    do: Map.put(args, "modifier", modifiers)

  defp add_modifiers(args, _params), do: args

  defp required_text(params, key, fun) do
    case params[key] do
      text when is_binary(text) -> fun.(text)
      _ -> {:error, "#{key} is required"}
    end
  end

  defp coordinate([x, y]) when is_integer(x) and is_integer(y), do: [x, y]
  defp coordinate(_), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp positive_integer(_), do: nil

  defp safe_target(nil), do: nil
  defp safe_target(%{kind: :desktop}), do: %{"kind" => "desktop"}

  defp safe_target(target) do
    %{
      "kind" => "window",
      "pid" => target.pid,
      "windowId" => target.window_id,
      "app" => target.app,
      "title" => target.title
    }
  end

  defp exact_scope(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, %{session_id: session_id, run_id: Keyword.get(opts, :run_id)}}

      _ ->
        {:error, {:missing_computer_use_binding, :session_id}}
    end
  end

  defp ensure_started(scope, opts) do
    name = {:via, Registry, {@registry, scope}}

    case Registry.lookup(@registry, scope) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        child_opts = [
          scope: scope,
          name: name,
          computer_use_runner: Keyword.get(opts, :computer_use_runner),
          cua_driver_path: Keyword.get(opts, :cua_driver_path),
          cua_socket_path: Keyword.get(opts, :cua_socket_path)
        ]

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: min(value, 120_000)
  defp normalize_timeout(_), do: @default_timeout_ms

  defp touch(state, error) do
    %{
      state
      | request_count: state.request_count + 1,
        last_error:
          if(is_nil(error), do: nil, else: error |> inspect(limit: 8) |> String.slice(0, 300)),
        last_used_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
