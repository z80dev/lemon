defmodule LemonBrowser.TernSession do
  @moduledoc """
  Exact Lemon session/run/pane owner of one native Tern browser block.

  Owned PiPs close on idle expiry, run completion, or explicit close. Blocks
  adopted through targetId are released, never closed. Socket discovery belongs
  exclusively to LemonCore.Tern; invocation options cannot supply a socket path.
  """
  use GenServer

  alias LemonBrowser.RoutePolicy
  alias LemonCore.Tern

  @registry LemonBrowser.TernSessionRegistry
  @supervisor LemonBrowser.TernSessionSupervisor
  @idle_ms 300_000
  @methods ~w(browser.navigate browser.tabs browser.tabOpen browser.tabActivate browser.tabClose browser.snapshot browser.getContent browser.click browser.type browser.hover browser.selectOption browser.press browser.scroll browser.evaluate browser.events browser.screenshot browser.waitForSelector)

  @point_script """
  function(s) {
    const e=document.querySelector(s); if(!e) throw new Error('Element not found');
    e.scrollIntoView({block:'center',inline:'center'});
    const r=e.getBoundingClientRect(), style=getComputedStyle(e);
    if(!r.width || !r.height || style.visibility==='hidden' || e.disabled)
      throw new Error('Element is not actionable');
    const x=r.left+r.width/2, y=r.top+r.height/2;
    const hit=document.elementFromPoint(x,y);
    if(hit!==e && !e.contains(hit)) throw new Error('Element is obscured');
    return {x,y};
  }
  """

  @select_script """
  function(s, values) {
    const e=document.querySelector(s); if(!e || e.tagName!=='SELECT') throw new Error('Select not found');
    if(e.disabled) throw new Error('Select is disabled');
    const option=Array.from(e.options).find(o=>o.value===values[0]);
    if(!option || option.disabled) throw new Error('Option not found or disabled');
    e.value=values[0]; e.dispatchEvent(new Event('input',{bubbles:true}));
    e.dispatchEvent(new Event('change',{bubbles:true})); return [e.value];
  }
  """

  @content_script """
  function() {
    const root=document.documentElement.cloneNode(true);
    root.querySelectorAll('script,style,noscript,template').forEach(e=>e.remove());
    root.querySelectorAll('input[type=password]').forEach(e=>e.removeAttribute('value'));
    return {url:location.href,title:document.title,html:root.outerHTML,
      text:(document.body?.innerText || '').replace(/\\s+/g,' ').trim()};
  }
  """

  @capture_script """
  function() {
    if(globalThis.__lemonTernCapture) return true;
    const handler=globalThis.webkit?.messageHandlers?.stencil;
    if(!handler) throw new Error('Tern page event bridge is unavailable');
    let budget=0, windowStart=Date.now();
    const post=(kind,data)=>{
      const now=Date.now(); if(now-windowStart>=1000) {budget=0;windowStart=now;}
      if(++budget>100) return;
      try { handler.postMessage(JSON.stringify({lemon:'tern',kind,ts:now,...data})); } catch {}
    };
    const text=value=>{try{return String(value).slice(0,16384);}catch{return '[unprintable]';}};
    const originals={}, wrappers={};
    for(const level of ['log','info','warn','error','debug']) {
      originals[level]=console[level];
      wrappers[level]=function(...args) {
        post('console',{level,text:args.map(text).join(' ').slice(0,16384)});
        return originals[level].apply(this,args);
      };
      console[level]=wrappers[level];
    }
    const error=e=>{
      if(e.target!==window && e.target?.tagName) {
        post('requestfailed',{url:text(e.target.src||e.target.href||''),errorText:'Resource failed'});
      } else post('pageerror',{message:text(e.message||e.error||'Uncaught error')});
    };
    const rejected=e=>post('pageerror',{message:text(e.reason||'Unhandled rejection')});
    addEventListener('error',error,true); addEventListener('unhandledrejection',rejected);
    globalThis.__lemonTernCapture={dispose() {
      for(const level of Object.keys(originals)) if(console[level]===wrappers[level]) console[level]=originals[level];
      removeEventListener('error',error,true); removeEventListener('unhandledrejection',rejected);
      delete globalThis.__lemonTernCapture;
    }};
    return true;
  }
  """
  @dispose_capture "function() { globalThis.__lemonTernCapture?.dispose(); return true; }"

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :scope)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 30_000
    }
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def request(method, args, timeout_ms, opts) do
    method = if String.starts_with?(method, "browser."), do: method, else: "browser." <> method

    with true <- method in @methods,
         {:ok, scope} <- exact_scope(opts),
         :ok <- guard_navigation(method, args),
         {:ok, pid} <- ensure_started(scope, opts) do
      GenServer.call(pid, {:request, method, args, timeout_ms}, timeout_ms + 30_000)
    else
      false -> unsupported(method)
      {:error, _} = error -> error
    end
  end

  def close(opts) do
    with {:ok, scope} <- exact_scope(opts) do
      if Process.whereis(@registry) do
        case Registry.lookup(@registry, scope) do
          [{pid, _}] -> GenServer.stop(pid, :normal, 30_000)
          [] -> :ok
        end
      else
        :ok
      end
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  def opened?(opts), do: lookup_value(opts, :opened?, false)
  def fallback(opts), do: lookup_value(opts, :fallback, nil)

  def put_fallback(opts, resolution) do
    with {:ok, scope} <- exact_scope(opts),
         {:ok, pid} <- ensure_started(scope, opts) do
      GenServer.call(pid, {:put_fallback, resolution})
    end
  end

  defp lookup_value(opts, message, default) do
    with {:ok, scope} <- exact_scope(opts),
         registry when is_pid(registry) <- Process.whereis(@registry),
         [{pid, _}] <- Registry.lookup(@registry, scope) do
      GenServer.call(pid, message)
    else
      _ -> default
    end
  rescue
    ArgumentError -> default
  catch
    :exit, _ -> default
  end

  def status do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
    |> Enum.flat_map(fn pid ->
      try do
        [GenServer.call(pid, :status, 1_000)]
      catch
        :exit, _ -> []
      end
    end)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    scope = Keyword.fetch!(opts, :scope)
    if scope.run_id, do: LemonCore.Bus.subscribe("run:" <> scope.run_id)
    idle = normalize_idle(Keyword.get(opts, :browser_idle_timeout_ms))

    {:ok,
     %{
       scope: scope,
       client: nil,
       block: nil,
       adopted: false,
       cursor: 0,
       events: [],
       fallback: nil,
       idle_ms: idle,
       timer: nil,
       deadline: nil,
       request_count: 0
     }, {:continue, :idle}}
  end

  @impl true
  def handle_continue(:idle, state), do: {:noreply, schedule_idle(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       provider: :tern,
       connected: is_pid(state.client),
       active: not is_nil(state.block),
       adopted: state.adopted,
       request_count: state.request_count,
       idle_timeout_ms: state.idle_ms
     }, state}
  end

  def handle_call(:opened?, _from, state), do: {:reply, not is_nil(state.block), state}

  def handle_call(:fallback, _from, state) do
    cancel_idle(state)
    {:reply, state.fallback, schedule_idle(state)}
  end

  def handle_call({:put_fallback, resolution}, _from, %{block: nil} = state) do
    cancel_idle(state)
    {:reply, :ok, schedule_idle(%{state | fallback: resolution})}
  end

  def handle_call({:put_fallback, _resolution}, _from, state),
    do: {:reply, {:error, {:invalid, "Cannot replace an active Tern browser identity"}}, state}

  def handle_call({:request, method, args, timeout}, _from, state) do
    cancel_idle(state)
    state = %{state | deadline: now_ms() + timeout}

    {reply, state} =
      case ensure_client(state) do
        {:ok, connected} ->
          case dispatch(method, args, connected) do
            {:ok, result, next} -> {{:ok, result}, next}
            {:error, reason, next} -> {{:error, reason}, next}
            {:error, reason} -> {{:error, reason}, connected}
          end

        {:error, reason} ->
          {{:error, reason}, state}
      end

    state = %{state | request_count: state.request_count + 1, deadline: nil}
    {:reply, reply, schedule_idle(state)}
  end

  @impl true
  def handle_info({:idle_timeout, token}, %{timer: {_ref, token}} = state),
    do: {:stop, :normal, state}

  def handle_info(%LemonCore.Event{type: :run_completed}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, pid, _reason}, %{client: pid} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup_block(state)
    if is_pid(state.client), do: Tern.close(state.client)
    :ok
  end

  defp ensure_started(scope, opts) do
    name = {:via, Registry, {@registry, scope}}

    case Registry.lookup(@registry, scope) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_opts = [
          scope: scope,
          name: name,
          browser_idle_timeout_ms: Keyword.get(opts, :browser_idle_timeout_ms)
        ]

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end
    end
  end

  defp exact_scope(opts) do
    session = Keyword.get(opts, :session_id)
    run = Keyword.get(opts, :run_id)

    with true <- is_binary(session) and byte_size(session) > 0,
         true <- is_nil(run) or (is_binary(run) and byte_size(run) > 0),
         true <- is_integer(Keyword.get(opts, :tern_pane)),
         {:ok, pane} <- Tern.pane(Keyword.get(opts, :tern_pane)) do
      {:ok, %{session_id: session, run_id: run, pane: pane}}
    else
      _ ->
        {:error, {:invalid, "Tern browser requires an exact session/run and tern_pane binding"}}
    end
  end

  defp ensure_client(%{client: client} = state) when is_pid(client), do: {:ok, state}

  defp ensure_client(state) do
    with {:ok, client} <- Tern.connect() do
      if Tern.supports?(client, "browser") do
        {:ok, %{state | client: client}}
      else
        Tern.close(client)
        {:error, {:unsupported, "Tern daemon does not advertise browser automation"}}
      end
    end
  end

  defp dispatch("browser.tabs", _args, state) do
    with {:ok, answer} <- op(state, "blocks", %{}, false),
         {:ok, blocks} <- block_list(answer) do
      tabs =
        Enum.map(blocks, fn block ->
          %{
            "targetId" => Integer.to_string(block["block"]),
            "url" => block["url"],
            "title" => block["title"],
            "active" => block["block"] == state.block,
            "driven" => block["driven"],
            "owner" => block["owner"]
          }
        end)

      {:ok, %{"tabs" => tabs, "activeTargetId" => target_id(state.block)}, state}
    end
  end

  defp dispatch("browser.tabClose", args, state) do
    with {:ok, target} <- target(args["targetId"]),
         true <- target == state.block,
         :ok <- uninstall_capture(state),
         {:ok, _} <- op(state, if(state.adopted, do: "release", else: "close")) do
      {:ok,
       %{
         "closed" => not state.adopted,
         "released" => state.adopted,
         "targetId" => target_id(target)
       }, %{state | block: nil, adopted: false, cursor: 0, events: []}}
    else
      false -> {:error, {:not_found, "Target is not owned by this Lemon session"}}
      {:error, _} = error -> error
    end
  end

  defp dispatch("browser.tabOpen", _args, %{block: block}) when not is_nil(block),
    do: unsupported("Tern supports one browser block per exact Lemon session/run")

  defp dispatch(method, args, state) do
    fresh = is_nil(state.block)

    with {:ok, state} <- ensure_block(state, args) do
      case page_request(method, args, state) do
        {:ok, result, next} ->
          {:ok, result, next}

        {:ok, result} ->
          {:ok, result, state}

        {:error, reason} ->
          if fresh and method in ["browser.navigate", "browser.tabOpen"] do
            case cleanup_block(state) do
              :ok ->
                {:error, reason, %{state | block: nil, adopted: false, cursor: 0, events: []}}

              {:error, _} ->
                {:error, reason, state}
            end
          else
            {:error, reason, state}
          end
      end
    end
  end

  defp ensure_block(state, %{"targetId" => value}) do
    with {:ok, block} <- target(value) do
      cond do
        state.block == block ->
          {:ok, state}

        not is_nil(state.block) ->
          {:error, {:invalid, "Target differs from this session's Tern block"}}

        true ->
          adopt(state, block)
      end
    end
  end

  defp ensure_block(%{block: block} = state, _args) when not is_nil(block), do: {:ok, state}

  defp ensure_block(state, _args) do
    with {:ok, %{"block" => block}} <-
           op(
             state,
             "open",
             %{
               "owner" => state.scope.pane,
               "url" => "about:blank",
               "width" => 1280,
               "height" => 720
             },
             false
           ),
         {:ok, block} <- target(block) do
      configure(%{state | block: block})
    else
      {:ok, _} -> {:error, {:protocol, "Tern open answered without a valid block"}}
      {:error, _} = error -> error
    end
  end

  defp adopt(state, block) do
    with {:ok, answer} <- op(state, "blocks", %{}, false),
         {:ok, blocks} <- block_list(answer),
         %{} = found <- Enum.find(blocks, &(&1["block"] == block)),
         false <- found["driven"] == true do
      configure(%{state | block: block, adopted: true})
    else
      nil -> {:error, {:not_found, "Tern browser target was not found"}}
      true -> {:error, {:invalid, "Tern browser target is already driven"}}
      {:error, _} = error -> error
    end
  end

  defp configure(state) do
    result =
      with {:ok, initial} <- op(state, "events", %{"after" => 0}),
           :ok <- initial_load(state, initial),
           {:ok, _} <- op(state, "dialogs", %{"policy" => "default"}),
           {:ok, _} <-
             op(state, "scripts", %{
               "scripts" => [
                 %{
                   "source" => "(" <> @capture_script <> ")();",
                   "world" => "page",
                   "frames" => "all",
                   "at" => "start"
                 }
               ]
             }),
           {:ok, _} <- evaluate(state, @capture_script, [], "page") do
        {:ok, %{state | cursor: Map.get(initial, "next", 0)}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        case cleanup_block(state) do
          :ok -> {:error, reason}
          {:error, _} -> {:error, reason, state}
        end
    end
  end

  defp initial_load(%{adopted: true}, _initial), do: :ok

  defp initial_load(state, initial) do
    if Enum.any?(Map.get(initial, "events", []), &(&1["type"] in ["loaded", "failed"])) do
      :ok
    else
      wait_loaded(state, Map.get(initial, "next", 0))
      |> case do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp page_request(method, args, state) when method in ["browser.navigate", "browser.tabOpen"] do
    url = Map.get(args, "url", "about:blank")

    with {:ok, policy} <- RoutePolicy.validate_navigation(url, Map.get(args, "route", "auto")),
         {:ok, before} <- op(state, "events", %{"after" => 0}),
         {:ok, current} <- op(state, "state"),
         {:ok, _} <- navigate(state, url, current),
         {:ok, _} <- wait_loaded(state, Map.get(before, "next", 0)),
         {:ok, result} <- op(state, "state") do
      {:ok,
       result
       |> Map.take(["url", "title", "shown"])
       |> Map.merge(%{
         "targetId" => target_id(state.block),
         "active" => true,
         "navigationPolicy" => RoutePolicy.safe(policy)
       })}
    end
  end

  defp page_request("browser.tabActivate", _args, state) do
    with {:ok, result} <- op(state, "state") do
      {:ok, Map.merge(result, %{"targetId" => target_id(state.block), "active" => true})}
    end
  end

  defp page_request("browser.snapshot", args, state) do
    if args["interactiveOnly"] == true or args["includeText"] == false do
      unsupported("Tern native snapshot does not support interactiveOnly/includeText=false")
    else
      fields = %{
        "nodes" => positive(args["maxNodes"], 350),
        "format" => "text",
        "mode" => "outline"
      }

      fields = if args["selector"], do: Map.put(fields, "root", args["selector"]), else: fields

      with {:ok, result} <- op(state, "snapshot", fields),
           {:ok, text} <- snapshot_text(result) do
        limit = positive(args["maxChars"], 12_000)
        truncated = String.length(text) > limit

        output =
          Map.merge(result, %{
            "mode" => "tern-native",
            "snapshot" => String.slice(text, 0, limit),
            "truncated" => truncated,
            "originalChars" => String.length(text)
          })

        {:ok,
         if(truncated, do: Map.put(output, "__full_content", %{"snapshot" => text}), else: output)}
      end
    end
  end

  defp page_request("browser.evaluate", args, state) do
    with {:ok, expression} <- required_string(args["expression"] || args["script"], "expression"),
         {:ok, value} <-
           evaluate(state, "function () { return (" <> expression <> "\n); }", [], "page") do
      {:ok, %{"result" => value}}
    end
  end

  defp page_request("browser.getContent", args, state) do
    if args["includeHtml"] == false and args["includeText"] == false do
      {:error, {:invalid, "getContent requires includeHtml or includeText"}}
    else
      with {:ok, content} <- evaluate(state, @content_script, [], "isolated") do
        fields =
          if args["includeHtml"] == false,
            do: [],
            else: [{"html", "truncated", "originalChars", positive(args["maxChars"], 20_000)}]

        fields =
          if args["includeText"] == false,
            do: fields,
            else:
              fields ++
                [
                  {"text", "textTruncated", "originalTextChars",
                   positive(args["textMaxChars"], 12_000)}
                ]

        result =
          Enum.reduce(fields, Map.take(content, ["url", "title"]), fn {key, flag, count, limit},
                                                                      acc ->
            text = content[key]

            acc
            |> Map.put(key, String.slice(text, 0, limit))
            |> Map.put(flag, String.length(text) > limit)
            |> Map.put(count, String.length(text))
          end)

        full = Map.take(content, Enum.map(fields, &elem(&1, 0)))
        truncated = result["truncated"] == true or result["textTruncated"] == true
        {:ok, if(truncated, do: Map.put(result, "__full_content", full), else: result)}
      end
    end
  end

  defp page_request("browser.screenshot", args, state) do
    type = if args["type"] == "jpeg", do: "jpeg", else: "png"
    fields = %{"format" => type, "full" => args["fullPage"] == true}

    with {:ok, %{"data" => data}} when is_binary(data) <- op(state, "capture", fields) do
      # The tool layer owns saving, retention, includeImage, and channel delivery.
      {:ok, %{"base64" => data, "contentType" => "image/" <> type}}
    else
      {:ok, _} -> {:error, {:protocol, "Tern capture answered without image data"}}
      {:error, _} = error -> error
    end
  end

  defp page_request("browser.events", args, state) do
    with {:ok, answer} <- op(state, "events", %{"after" => state.cursor}) do
      incoming = Enum.map(Map.get(answer, "events", []), &normalize_event/1)
      buffered = Enum.take(state.events ++ incoming, -100)
      limit = min(positive(args["limit"], 50), 100)
      clear = args["clear"] == true

      {:ok,
       %{
         "events" => Enum.take(buffered, -limit),
         "count" => length(buffered),
         "cleared" => clear
       },
       %{
         state
         | cursor: Map.get(answer, "next", state.cursor),
           events: if(clear, do: [], else: buffered)
       }}
    end
  end

  defp page_request("browser.click", args, state),
    do: pointer_action(state, args, "click", "clicked")

  defp page_request("browser.hover", args, state),
    do: pointer_action(state, args, "hover", "hovered")

  defp page_request("browser.type", args, state) do
    with {:ok, selector} <- required_string(args["selector"], "selector"),
         {:ok, text} <- required_text(args["text"]) do
      if reference?(selector) and args["useFill"] == true do
        act_result(state, "fill", selector, %{"text" => text}, %{
          "typed" => true,
          "length" => text_units(text)
        })
      else
        with :ok <- focus(state, selector),
             :ok <- clear_input(state, args),
             :ok <- type_text(state, text, args["delayMs"], args["useFill"] == true) do
          {:ok, %{"typed" => true, "length" => text_units(text)}}
        end
      end
    end
  end

  defp page_request("browser.press", args, state) do
    with {:ok, key} <- required_string(args["key"], "key") do
      selector = args["selector"]

      cond do
        is_binary(selector) and reference?(selector) ->
          act_result(state, "press", selector, %{"keys" => key}, %{
            "pressed" => true,
            "key" => key
          })

        true ->
          with :ok <- maybe_focus(state, selector),
               {:ok, steps} <- key_steps(key),
               {:ok, _} <- op(state, "input", %{"events" => steps}) do
            {:ok, %{"pressed" => true, "key" => key}}
          end
      end
    end
  end

  defp page_request("browser.selectOption", args, state) do
    values = args["values"] || [args["value"]]

    with {:ok, selector} <- required_string(args["selector"], "selector") do
      case values do
        [value] when is_binary(value) ->
          if reference?(selector) do
            act_result(state, "select", selector, %{"text" => value}, %{
              "selected" => [value],
              "count" => 1
            })
          else
            with {:ok, selected} <-
                   evaluate(state, @select_script, [selector, values], "isolated") do
              {:ok, %{"selected" => selected, "count" => length(selected)}}
            end
          end

        _ ->
          unsupported("Tern selectOption currently requires one option value")
      end
    end
  end

  defp page_request("browser.scroll", args, state) do
    cond do
      args["selector"] ->
        selector = args["selector"]

        if reference?(selector) do
          act_result(state, "scroll", selector, %{"dx" => 0, "dy" => 0}, %{"scrolled" => true})
        else
          with {:ok, _} <-
                 evaluate(
                   state,
                   "function (s) { const e=document.querySelector(s); if(!e) throw new Error('Element not found'); e.scrollIntoView({block:'center',inline:'center'}); return true; }",
                   [selector],
                   "isolated"
                 ),
               {:ok, position} <- scroll_position(state) do
            {:ok, %{"scrolled" => true, "position" => position}}
          end
        end

      args["absolute"] == true or args["to"] == true ->
        with {:ok, position} <-
               evaluate(
                 state,
                 "function(x,y) { window.scrollTo(x,y); return {x:scrollX,y:scrollY}; }",
                 [number(args["x"], 0), number(args["y"], 600)],
                 "isolated"
               ) do
          {:ok, %{"scrolled" => true, "position" => position}}
        end

      true ->
        step = %{
          "type" => "wheel",
          "x" => 1,
          "y" => 1,
          "dx" => number(args["x"] || args["deltaX"], 0),
          "dy" => number(args["y"] || args["deltaY"], 600)
        }

        with {:ok, _} <- op(state, "input", %{"events" => [step]}),
             {:ok, position} <- scroll_position(state) do
          {:ok, %{"scrolled" => true, "position" => position}}
        end
    end
  end

  defp page_request("browser.waitForSelector", args, state) do
    with {:ok, selector} <- required_string(args["selector"], "selector"),
         :ok <- wait_selector(state, selector) do
      {:ok, %{"found" => true}}
    end
  end

  defp normalize_event(%{"type" => "message", "world" => "page", "body" => body} = event)
       when is_binary(body) do
    with {:ok, %{"lemon" => "tern", "kind" => kind, "ts" => ts} = message} <- Jason.decode(body),
         true <- is_binary(kind) and is_integer(ts),
         {:ok, timestamp} <- DateTime.from_unix(ts, :millisecond) do
      message
      |> Map.drop(["lemon", "kind", "ts"])
      |> Map.put("type", kind)
      |> Map.put("timestamp", DateTime.to_iso8601(timestamp))
    else
      _ -> event
    end
  end

  defp normalize_event(event), do: event

  defp pointer_action(state, args, action, flag) do
    with {:ok, selector} <- required_string(args["selector"], "selector") do
      if reference?(selector) do
        act_result(state, action, selector, %{}, %{flag => true})
      else
        with {:ok, point} <- evaluate(state, @point_script, [selector], "isolated"),
             {:ok, _} <- op(state, "input", %{"events" => mouse_steps(action, point)}) do
          {:ok, %{flag => true}}
        end
      end
    end
  end

  defp act_result(state, action, ref, fields, result) do
    with {:ok, _} <- op(state, "act", Map.merge(%{"action" => action, "ref" => ref}, fields)),
         do: {:ok, result}
  end

  defp focus(state, selector) do
    if reference?(selector) do
      with {:ok, _} <- act_result(state, "click", selector, %{}, %{}), do: :ok
    else
      with {:ok, _} <-
             evaluate(
               state,
               "function(s) { const e=document.querySelector(s); if(!e) throw new Error('Element not found'); e.scrollIntoView({block:'center'}); e.focus(); if(document.activeElement!==e) throw new Error('Element cannot receive input'); return true; }",
               [selector],
               "isolated"
             ),
           do: :ok
    end
  end

  defp maybe_focus(_state, nil), do: :ok
  defp maybe_focus(state, selector), do: focus(state, selector)

  defp clear_input(state, args) do
    if args["clear"] == true or args["useFill"] == true do
      # Tern's native browser runs on macOS; Meta+A selects the focused input.
      with {:ok, select} <- key_steps("Meta+a"),
           {:ok, delete} <- key_steps("Backspace"),
           {:ok, _} <- op(state, "input", %{"events" => select ++ delete}),
           do: :ok
    else
      :ok
    end
  end

  defp type_text(state, text, _delay, true),
    do: send_input(state, [%{"type" => "text", "text" => text}])

  defp type_text(state, text, delay, false) when is_number(delay) and delay > 0 do
    Enum.reduce_while(String.codepoints(text), :ok, fn char, :ok ->
      case send_input(state, typing_steps(char)) do
        :ok ->
          Process.sleep(min(trunc(delay), max(remaining(state), 0)))
          {:cont, :ok}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp type_text(state, text, _delay, false), do: send_input(state, typing_steps(text))

  defp send_input(_state, []), do: :ok

  defp send_input(state, steps) do
    with {:ok, _} <- op(state, "input", %{"events" => steps}), do: :ok
  end

  defp typing_steps(text), do: typing_steps(text, [])
  defp typing_steps(<<>>, acc), do: Enum.reverse(acc)

  defp typing_steps(<<char::utf8, rest::binary>>, acc) do
    steps =
      if char in 32..126 or char in [9, 10, 13] do
        {:ok, steps} = key_steps(<<char::utf8>>)
        steps
      else
        [%{"type" => "text", "text" => <<char::utf8>>}]
      end

    typing_steps(rest, Enum.reverse(steps, acc))
  end

  # Match the Node driver's JavaScript string.length (UTF-16 code units).
  defp text_units(text), do: text_units(text, 0)
  defp text_units(<<>>, count), do: count

  defp text_units(<<char::utf8, rest::binary>>, count),
    do: text_units(rest, count + if(char > 0xFFFF, do: 2, else: 1))

  defp key_steps(chord) do
    parts =
      cond do
        chord == "+" ->
          ["+"]

        String.ends_with?(chord, "+") ->
          String.split(String.trim_trailing(chord, "+"), "+") ++ ["+"]

        true ->
          String.split(chord, "+")
      end

    {modifiers, keys} = Enum.split(parts, -1)

    names = %{
      "Control" => {"Control", "ctrl"},
      "ControlOrMeta" => {"Meta", "meta"},
      "Meta" => {"Meta", "meta"},
      "Alt" => {"Alt", "alt"},
      "Shift" => {"Shift", "shift"}
    }

    with true <- length(keys) == 1 and Enum.all?(modifiers, &Map.has_key?(names, &1)),
         {:ok, key, code} <- key_value(hd(keys)) do
      {down, mods} =
        Enum.map_reduce(modifiers, [], fn name, held ->
          {key, mod} = Map.fetch!(names, name)
          {key_step("down", key, key <> "Left", held), held ++ [mod]}
        end)

      key = if "shift" in mods and key =~ ~r/^[a-z]$/, do: String.upcase(key), else: key

      {up, _} =
        Enum.map_reduce(Enum.reverse(modifiers), mods, fn name, held ->
          {key, mod} = Map.fetch!(names, name)
          rest = List.delete(held, mod)
          {key_step("up", key, key <> "Left", rest), rest}
        end)

      {:ok, down ++ [key_step("down", key, code, mods), key_step("up", key, code, mods)] ++ up}
    else
      _ -> unsupported("Tern does not support this key name or chord")
    end
  end

  defp key_value("Space"), do: {:ok, " ", "Space"}
  defp key_value(" "), do: {:ok, " ", "Space"}
  defp key_value("\n"), do: {:ok, "Enter", "Enter"}
  defp key_value("\r"), do: {:ok, "Enter", "Enter"}
  defp key_value("\t"), do: {:ok, "Tab", "Tab"}

  defp key_value("Key" <> <<letter>>) when letter in ?A..?Z,
    do: {:ok, String.downcase(<<letter>>), "Key" <> <<letter>>}

  defp key_value("Digit" <> <<digit>>) when digit in ?0..?9,
    do: {:ok, <<digit>>, "Digit" <> <<digit>>}

  defp key_value(key) do
    cond do
      key =~ ~r/^[a-z]$/i ->
        {:ok, key, "Key" <> String.upcase(key)}

      key =~ ~r/^[0-9]$/ ->
        {:ok, key, "Digit" <> key}

      String.length(key) == 1 ->
        {:ok, key, nil}

      key in ["Shift", "Control", "Alt", "Meta"] ->
        {:ok, key, key <> "Left"}

      key =~
          ~r/^(Enter|Tab|Backspace|Delete|Escape|ArrowUp|ArrowDown|ArrowLeft|ArrowRight|Home|End|PageUp|PageDown|Insert|CapsLock|ContextMenu|F([1-9]|1[0-9]|2[0-4]))$/ ->
        {:ok, key, key}

      true ->
        {:error, :invalid_key}
    end
  end

  defp key_step(action, key, code, mods) do
    step = %{"type" => "key", "action" => action, "key" => key, "mods" => mods}
    if code, do: Map.put(step, "code", code), else: step
  end

  defp mouse_steps(action, %{"x" => x, "y" => y}) do
    move = %{"type" => "mouse", "action" => "move", "x" => x, "y" => y}

    if action == "hover",
      do: [move],
      else: [
        move,
        Map.merge(move, %{"action" => "down", "button" => "left", "clicks" => 1}),
        Map.merge(move, %{"action" => "up", "button" => "left", "clicks" => 1})
      ]
  end

  defp scroll_position(state),
    do: evaluate(state, "function() { return {x:scrollX,y:scrollY}; }", [], "isolated")

  defp wait_selector(state, selector) do
    if reference?(selector) do
      with {:ok, _} <- op(state, "snapshot", %{"root" => selector, "nodes" => 1}), do: :ok
    else
      with {:ok, found} <-
             evaluate(
               state,
               "function(s) { const e=document.querySelector(s); if(!e) return false; const r=e.getBoundingClientRect(); return r.width>0 && r.height>0 && getComputedStyle(e).visibility!=='hidden'; }",
               [selector],
               "isolated"
             ) do
        if found, do: :ok, else: pause(state, fn -> wait_selector(state, selector) end)
      end
    end
  end

  defp navigate(state, url, %{"url" => url}), do: op(state, "nav", %{"go" => "reload"})
  defp navigate(state, url, _current), do: op(state, "goto", %{"url" => url})

  defp wait_loaded(state, cursor) do
    with {:ok, answer} <- op(state, "events", %{"after" => cursor}) do
      events = Map.get(answer, "events", [])

      cond do
        Enum.any?(events, &(&1["type"] == "failed")) ->
          {:error, {:failed, "Tern page navigation failed"}}

        Enum.any?(events, &(&1["type"] == "loaded")) ->
          {:ok, answer}

        true ->
          pause(state, fn -> wait_loaded(state, Map.get(answer, "next", cursor)) end)
      end
    end
  end

  defp pause(state, fun) do
    if remaining(state) > 0 do
      Process.sleep(min(50, remaining(state)))
      fun.()
    else
      {:error, {:timeout, "Tern browser request timed out"}}
    end
  end

  defp evaluate(state, source, args, world) do
    with {:ok, %{"value" => value}} <-
           op(state, "eval", %{"function" => source, "args" => args, "world" => world}) do
      {:ok, value}
    else
      {:ok, answer} when is_map(answer) -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp op(state, operation, fields \\ %{}, scoped \\ true) do
    timeout = remaining(state)

    if timeout > 0 do
      payload = Map.put(fields, "op", operation)
      payload = if scoped, do: Map.put(payload, "block", state.block), else: payload
      Tern.request(state.client, "browser", payload, timeout)
    else
      {:error, {:timeout, "Tern browser request timed out"}}
    end
  end

  defp cleanup_block(%{block: nil}), do: :ok

  defp cleanup_block(state) do
    if is_pid(state.client) and Process.alive?(state.client) do
      cleanup_with_client(state.client, state)
    else
      # Reconnecting here is cleanup only: browser actions are never retried.
      case Tern.connect() do
        {:ok, client} ->
          try do
            cleanup_with_client(client, state)
          after
            Tern.close(client)
          end

        {:error, _} = error ->
          error
      end
    end
  catch
    :exit, _ -> {:error, {:closed, "Tern browser cleanup connection closed"}}
  end

  defp cleanup_with_client(client, state) do
    if state.adopted do
      Tern.request(
        client,
        "browser",
        %{
          "op" => "eval",
          "block" => state.block,
          "function" => @dispose_capture,
          "args" => [],
          "world" => "page"
        },
        5_000
      )
    end

    case Tern.request(
           client,
           "browser",
           %{"op" => if(state.adopted, do: "release", else: "close"), "block" => state.block},
           5_000
         ) do
      {:ok, _} -> :ok
      {:error, {:not_found, _}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp uninstall_capture(%{adopted: false}), do: :ok

  defp uninstall_capture(state) do
    _ = evaluate(state, @dispose_capture, [], "page")
    :ok
  end

  defp block_list(%{"blocks" => blocks}) when is_list(blocks), do: validate_blocks(blocks)
  defp block_list(blocks) when is_list(blocks), do: validate_blocks(blocks)
  defp block_list(_), do: {:error, {:protocol, "Tern answered without a browser block list"}}

  defp validate_blocks(blocks) do
    if Enum.all?(blocks, fn block ->
         is_map(block) and match?({:ok, _}, Tern.pane(block["block"]))
       end),
       do: {:ok, blocks},
       else: {:error, {:protocol, "Tern returned invalid browser block IDs"}}
  end

  defp snapshot_text(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp snapshot_text(%{"tree" => text}) when is_binary(text), do: {:ok, text}
  defp snapshot_text(_), do: {:error, {:protocol, "Tern native snapshot answered without text"}}

  defp target(value) do
    case Tern.pane(value) do
      {:ok, _} = ok -> ok
      _ -> {:error, {:invalid, "Tern targetId must be a nonnegative browser block ID"}}
    end
  end

  defp target_id(nil), do: nil
  defp target_id(block), do: Integer.to_string(block)

  defp reference?(value),
    do:
      is_binary(value) and (String.starts_with?(value, "@") or Regex.match?(~r/^e[0-9]+$/, value))

  defp required_string(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp required_string(_value, field), do: {:error, {:invalid, field <> " is required"}}
  defp required_text(value) when is_binary(value), do: {:ok, value}
  defp required_text(_), do: {:error, {:invalid, "text must be a string"}}

  defp unsupported(method),
    do: {:error, {:unsupported, "Unsupported Tern browser operation: " <> method}}

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(state), do: max(0, state.deadline - now_ms())
  defp normalize_idle(value) when is_integer(value) and value > 0, do: min(value, 3_600_000)
  defp normalize_idle(_), do: @idle_ms
  defp cancel_idle(%{timer: {ref, _}}), do: Process.cancel_timer(ref)
  defp cancel_idle(_), do: :ok

  defp schedule_idle(state) do
    token = make_ref()
    ref = Process.send_after(self(), {:idle_timeout, token}, state.idle_ms)
    %{state | timer: {ref, token}}
  end

  defp guard_navigation(method, args) when method in ["browser.navigate", "browser.tabOpen"] do
    case RoutePolicy.validate_navigation(
           Map.get(args, "url", "about:blank"),
           Map.get(args, "route", "auto")
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid, reason}}
    end
  end

  defp guard_navigation(_method, _args), do: :ok
end
