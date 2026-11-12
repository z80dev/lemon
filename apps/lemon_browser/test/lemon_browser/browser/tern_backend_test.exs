defmodule LemonBrowser.TernBackendTest do
  use ExUnit.Case, async: false
  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonBrowser.{BackendRegistry, TernSession}
  alias LemonBrowser.Backends.Tern

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-tern-browser-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
    test_pid = self()

    {:ok, daemon} =
      Agent.start(fn ->
        %{
          next: 100,
          ops: ["browser"],
          failure: nil,
          blocks: %{
            90 => %{
              url: "https://user.example/",
              title: "User page",
              seq: 1,
              driven: false,
              owner: nil
            }
          }
        }
      end)

    acceptor = spawn(fn -> accept_loop(listener, daemon, test_pid) end)
    old_socket = System.get_env("TERN_PANE_SOCKET")
    old_optout = System.get_env("LEMON_BROWSER_TERN")
    System.put_env("TERN_PANE_SOCKET", path)
    System.delete_env("LEMON_BROWSER_TERN")

    on_exit(fn ->
      LemonBrowser.TernSessionRegistry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
      |> Enum.each(fn pid ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 15_000)
      end)

      :gen_tcp.close(listener)
      Process.exit(acceptor, :kill)
      if Process.alive?(daemon), do: Agent.stop(daemon)
      File.rm(path)
      restore_env("TERN_PANE_SOCKET", old_socket)
      restore_env("LEMON_BROWSER_TERN", old_optout)
    end)

    opts = [
      session_id: "session",
      run_id: "run",
      tern_pane: 7,
      provider_config: %{tern: true},
      browser_idle_timeout_ms: 5_000
    ]

    {:ok, opts: opts, daemon: daemon}
  end

  test "registry includes the native backend and availability requires browser handshake", %{
    opts: opts,
    daemon: daemon
  } do
    assert {:ok, Tern} = BackendRegistry.fetch(:tern)
    assert Tern.available?(opts)
    refute Tern.available?(Keyword.put(opts, :tern_pane, -1))
    refute Tern.available?(Keyword.put(opts, :provider_config, %{tern: false}))
    System.put_env("LEMON_BROWSER_TERN", "0")
    refute Tern.available?(opts)
    System.delete_env("LEMON_BROWSER_TERN")
    Agent.update(daemon, &%{&1 | ops: []})
    refute Tern.available?(opts)
    refute_received {:tern, %{"op" => "open"}}
  end

  test "opens blank on exact owner, configures, then navigates and reuses the PiP", %{opts: opts} do
    assert {:ok, %{"url" => "https://example.com/", "targetId" => "100"}} =
             request("navigate", %{"url" => "https://example.com/"}, opts)

    assert_received {:tern, %{"op" => "open", "owner" => 7, "url" => "about:blank"}}
    assert_received {:tern, %{"op" => "events", "block" => 100}}
    assert_received {:tern, %{"op" => "dialogs", "block" => 100, "policy" => "default"}}
    assert_received {:tern, %{"op" => "goto", "block" => 100, "url" => "https://example.com/"}}
    assert TernSession.opened?(opts)
    assert {:ok, _} = request("snapshot", %{}, opts)
    refute_received {:tern, %{"op" => "open"}}
    assert {:error, {:unsupported, _}} = request("tabOpen", %{}, opts)
  end

  test "navigation policy rejects metadata and mismatched routes before opening", %{opts: opts} do
    assert {:error, {:invalid, _}} =
             request("navigate", %{"url" => "http://169.254.169.254/latest"}, opts)

    assert {:error, {:invalid, _}} =
             request("tabOpen", %{"url" => "http://127.0.0.1", "route" => "public"}, opts)

    refute_received {:tern, _}
    refute TernSession.opened?(opts)
  end

  test "native snapshot refs flow into act and truncated snapshots preserve full content", %{
    opts: opts
  } do
    assert {:ok,
            %{
              "snapshot" => "[",
              "truncated" => true,
              "__full_content" => %{"snapshot" => "[@e1] button Save"}
            }} = request("snapshot", %{"maxChars" => 1}, opts)

    assert {:ok, %{"clicked" => true}} = request("click", %{"selector" => "@e1"}, opts)
    assert_received {:tern, %{"op" => "act", "action" => "click", "ref" => "@e1"}}

    assert {:ok, %{"typed" => true, "length" => 5}} =
             request("type", %{"selector" => "@e1", "text" => "hello", "useFill" => true}, opts)

    assert_received {:tern,
                     %{"op" => "act", "action" => "fill", "ref" => "@e1", "text" => "hello"}}

    assert {:ok, %{"pressed" => true}} =
             request("press", %{"selector" => "@e1", "key" => "Meta+a"}, opts)

    assert_received {:tern, %{"op" => "act", "action" => "press", "keys" => "Meta+a"}}

    assert {:ok, %{"selected" => ["one"]}} =
             request("selectOption", %{"selector" => "@e1", "value" => "one"}, opts)

    assert_received {:tern, %{"op" => "act", "action" => "select", "text" => "one"}}
  end

  test "CSS actions use isolated lookup and trusted input, eval uses the page world", %{
    opts: opts
  } do
    assert {:ok, %{"clicked" => true}} = request("click", %{"selector" => "#button"}, opts)
    assert_received {:tern, %{"op" => "eval", "world" => "isolated", "args" => ["#button"]}}

    assert_received {:tern,
                     %{
                       "op" => "input",
                       "events" => [
                         %{"type" => "mouse", "action" => "move", "x" => 10, "y" => 20},
                         %{"action" => "down", "button" => "left"},
                         %{"action" => "up", "button" => "left"}
                       ]
                     }}

    assert {:ok, %{"typed" => true}} =
             request("type", %{"selector" => "#input", "text" => "hello", "clear" => true}, opts)

    assert_received {:tern,
                     %{
                       "op" => "input",
                       "events" => [
                         %{"key" => "Meta", "action" => "down"},
                         %{"key" => "a", "mods" => ["meta"]} | _
                       ]
                     }}

    assert_received {:tern,
                     %{
                       "op" => "input",
                       "events" => [
                         %{"type" => "key", "action" => "down", "key" => "h"},
                         %{"type" => "key", "action" => "up", "key" => "h"} | _
                       ]
                     }}

    assert {:ok, %{"typed" => true, "length" => 2}} =
             request(
               "type",
               %{"selector" => "#input", "text" => "\u{10400}", "useFill" => true},
               opts
             )

    assert_received {:tern,
                     %{"op" => "input", "events" => [%{"type" => "text", "text" => "\u{10400}"}]}}

    assert {:ok, %{"result" => "Title"}} =
             request("evaluate", %{"expression" => "document.title"}, opts)

    assert_received {:tern,
                     %{
                       "op" => "eval",
                       "world" => "page",
                       "function" => "function () { return (document.title\n); }"
                     }}

    assert {:ok, %{"scrolled" => true}} = request("scroll", %{"deltaY" => 123}, opts)
    assert_received {:tern, %{"op" => "input", "events" => [%{"type" => "wheel", "dy" => 123}]}}
  end

  test "capture follows the existing artifact byte contract; events have bounded clear semantics",
       %{opts: opts} do
    assert {:ok, %{"base64" => "aW1hZ2U=", "contentType" => "image/jpeg"}} =
             request("screenshot", %{"type" => "jpeg", "fullPage" => true}, opts)

    assert_received {:tern, %{"op" => "capture", "format" => "jpeg", "full" => true}}
    assert {:ok, _} = request("navigate", %{"url" => "https://example.com"}, opts)

    assert {:ok, %{"events" => [_], "count" => 1, "cleared" => false}} =
             request("events", %{}, opts)

    assert {:ok, %{"count" => 1, "cleared" => true}} = request("events", %{"clear" => true}, opts)
    assert {:ok, %{"events" => [], "count" => 0}} = request("events", %{}, opts)
  end

  test "natural targetId adopts user blocks and close releases rather than closes", %{opts: opts} do
    assert {:ok, %{"tabs" => [%{"targetId" => "90"}]}} = request("tabs", %{}, opts)
    assert {:ok, _} = request("snapshot", %{"targetId" => "90"}, opts)
    refute_received {:tern, %{"op" => "open"}}

    assert {:ok, %{"released" => true, "closed" => false}} =
             request("tabClose", %{"targetId" => "90"}, opts)

    assert_received {:tern, %{"op" => "release", "block" => 90}}
    refute_received {:tern, %{"op" => "close", "block" => 90}}
  end

  test "adopted blocks release on session cleanup and driven targets fail closed", %{
    opts: opts,
    daemon: daemon
  } do
    Agent.update(daemon, &put_in(&1, [:blocks, 90, :driven], true))
    assert {:error, {:invalid, _}} = request("snapshot", %{"targetId" => "90"}, opts)
    Agent.update(daemon, &put_in(&1, [:blocks, 90, :driven], false))
    assert {:ok, _} = request("snapshot", %{"targetId" => "90"}, opts)
    assert :ok = TernSession.close(opts)
    assert_received {:tern, %{"op" => "release", "block" => 90}}
    refute_received {:tern, %{"op" => "close", "block" => 90}}
  end

  test "different exact run or pane never shares PiPs; explicit close closes only owned blocks",
       %{opts: opts} do
    assert {:ok, _} = request("snapshot", %{}, opts)
    assert {:ok, _} = request("snapshot", %{}, Keyword.put(opts, :run_id, "other"))
    assert {:ok, _} = request("snapshot", %{}, Keyword.put(opts, :tern_pane, 8))
    assert_received {:tern, %{"op" => "open", "owner" => 7}}
    assert_received {:tern, %{"op" => "open", "owner" => 7}}
    assert_received {:tern, %{"op" => "open", "owner" => 8}}
    assert {:error, {:invalid, _}} = request("snapshot", %{"targetId" => "101"}, opts)
    assert {:ok, %{"closed" => true}} = request("tabClose", %{"targetId" => "100"}, opts)
    assert_received {:tern, %{"op" => "close", "block" => 100}}
    refute TernSession.opened?(opts)
  end

  test "configuration and initial navigation failure clean up; later failure retains identity", %{
    opts: opts,
    daemon: daemon
  } do
    Agent.update(daemon, &%{&1 | failure: "dialogs"})
    assert {:error, {:unsupported, _}} = request("snapshot", %{}, opts)
    assert_received {:tern, %{"op" => "close", "block" => 100}}
    refute TernSession.opened?(opts)
    Agent.update(daemon, &%{&1 | failure: "goto"})

    assert {:error, {:unsupported, _}} =
             request("navigate", %{"url" => "https://example.com"}, opts)

    assert_received {:tern, %{"op" => "close", "block" => 101}}
    refute TernSession.opened?(opts)
    Agent.update(daemon, &%{&1 | failure: nil})
    assert {:ok, _} = request("navigate", %{"url" => "https://example.com"}, opts)
    Agent.update(daemon, &%{&1 | failure: "goto"})

    assert {:error, {:unsupported, _}} =
             request("navigate", %{"url" => "https://other.example"}, opts)

    assert TernSession.opened?(opts)
    refute_received {:tern, %{"op" => "close", "block" => 102}}
  end

  test "idle and run completion cleanup are bounded and fallback memory is exact scoped", %{
    opts: opts
  } do
    idle = Keyword.put(opts, :browser_idle_timeout_ms, 30)
    assert {:ok, _} = request("snapshot", %{}, idle)
    assert_receive {:tern, %{"op" => "close", "block" => 100}}, 2_000

    assert_eventually(fn ->
      Registry.lookup(LemonBrowser.TernSessionRegistry, %{
        session_id: "session",
        run_id: "run",
        pane: 7
      }) == []
    end)

    assert :ok = TernSession.put_fallback(opts, %{provider: "local"})
    assert %{provider: "local"} = TernSession.fallback(opts)
    assert nil == TernSession.fallback(Keyword.put(opts, :run_id, "other"))
    assert :ok = TernSession.close(opts)
    assert {:ok, _} = request("snapshot", %{}, opts)
    :ok = LemonCore.Bus.broadcast("run:run", LemonCore.Event.new(:run_completed, %{}))
    assert_receive {:tern, %{"op" => "close", "block" => 101}}, 2_000
  end

  test "unsupported methods and missing bindings never fabricate success or open a page", %{
    opts: opts
  } do
    for method <- [
          "back",
          "setInputFiles",
          "download",
          "getCookies",
          "setCookies",
          "clearState",
          "cdp"
        ] do
      assert {:error, {:unsupported, _}} = request(method, %{}, opts)
    end

    assert {:error, {:invalid, _}} = request("snapshot", %{}, Keyword.delete(opts, :session_id))
    assert {:error, {:invalid, _}} = request("snapshot", %{}, Keyword.delete(opts, :tern_pane))
    refute_received {:tern, _}
  end

  test "complete content survives truncation and native refs are not treated as CSS", %{
    opts: opts
  } do
    assert {:ok,
            %{
              "truncated" => true,
              "textTruncated" => true,
              "__full_content" => %{"html" => "<p>hello</p>", "text" => "hello"}
            }} =
             request("getContent", %{"maxChars" => 1, "textMaxChars" => 1}, opts)

    assert_received {:tern,
                     %{
                       "op" => "scripts",
                       "scripts" => [
                         %{
                           "world" => "page",
                           "frames" => "all",
                           "at" => "start",
                           "source" => source
                         }
                       ]
                     }}

    assert source =~ "console[level]"
    assert {:ok, %{"clicked" => true}} = request("click", %{"selector" => "e1"}, opts)
    assert_received {:tern, %{"op" => "act", "ref" => "e1"}}
    assert {:error, {:unsupported, _}} = request("snapshot", %{"interactiveOnly" => true}, opts)

    assert {:error, {:unsupported, _}} =
             request("selectOption", %{"selector" => "e1", "values" => ["a", "b"]}, opts)
  end

  test "page event messages are normalized and malformed page timestamps stay untrusted", %{
    opts: opts,
    daemon: daemon
  } do
    assert {:ok, _} = request("snapshot", %{}, opts)

    console = %{
      "type" => "message",
      "world" => "page",
      "seq" => 2,
      "body" =>
        Jason.encode!(%{lemon: "tern", kind: "console", ts: 1_000, level: "warn", text: "hello"})
    }

    Agent.update(daemon, fn state ->
      state |> put_in([:blocks, 100, :seq], 2) |> Map.put(:event, console)
    end)

    assert {:ok,
            %{
              "events" => [
                %{
                  "type" => "console",
                  "level" => "warn",
                  "text" => "hello",
                  "timestamp" => "1970-01-01T00:00:01.000Z"
                }
              ]
            }} =
             request("events", %{"clear" => true}, opts)

    Agent.update(daemon, fn state ->
      event = %{console | "seq" => 3, "body" => ~s({"lemon":"tern","kind":"console","ts":"bad"})}
      state |> put_in([:blocks, 100, :seq], 3) |> Map.put(:event, event)
    end)

    assert {:ok, %{"events" => [%{"type" => "message"}]}} = request("events", %{}, opts)
  end

  test "unconfirmed cleanup retains the identity binding and prevents fallback", %{
    opts: opts,
    daemon: daemon
  } do
    Agent.update(daemon, &%{&1 | failure: "dialogs_and_close"})

    assert {:error, {:unsupported, _}} =
             request("navigate", %{"url" => "https://example.com"}, opts)

    assert TernSession.opened?(opts)
    assert {:error, {:invalid, _}} = TernSession.put_fallback(opts, %{provider: "local"})
    Agent.update(daemon, &%{&1 | failure: nil})
    assert :ok = TernSession.close(opts)
  end

  test "exact session close is idempotent and tolerates simultaneous teardown", %{opts: opts} do
    assert :ok = TernSession.close(opts)
    assert {:ok, _} = request("snapshot", %{}, opts)
    tasks = for _ <- 1..2, do: Task.async(fn -> TernSession.close(opts) end)
    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [:ok, :ok]
    assert :ok = TernSession.close(opts)
  end

  defp request(method, args, opts), do: Tern.request("browser." <> method, args, 2_000, opts)

  defp accept_loop(listener, daemon, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker =
          spawn(fn ->
            receive do
              {:socket, socket} -> serve(socket, daemon, test_pid)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(listener, daemon, test_pid)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, daemon, test_pid) do
    with {:ok, <<size::little-unsigned-32>>} <- :gen_tcp.recv(socket, 4, 5_000),
         {:ok, json} <- :gen_tcp.recv(socket, size, 5_000) do
      request = Jason.decode!(json)

      answer =
        case request do
          %{"hello" => _} ->
            %{"welcome" => %{"ops" => Agent.get(daemon, & &1.ops)}}

          %{"id" => id, "browser" => payload} ->
            send(test_pid, {:tern, payload})
            result = Agent.get_and_update(daemon, &answer(payload, &1))
            %{"id" => id, "browser" => result}
        end

      encoded = Jason.encode!(answer)
      :ok = :gen_tcp.send(socket, <<byte_size(encoded)::little-unsigned-32, encoded::binary>>)
      serve(socket, daemon, test_pid)
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  defp answer(%{"op" => operation}, %{failure: "dialogs_and_close"} = state)
       when operation in ["dialogs", "close"],
       do: {%{"error" => %{"kind" => "unsupported", "message" => "Operation unavailable"}}, state}

  defp answer(%{"op" => operation}, %{failure: operation} = state),
    do: {%{"error" => %{"kind" => "unsupported", "message" => "Operation unavailable"}}, state}

  defp answer(%{"op" => "open", "owner" => owner}, state) do
    block = %{url: "about:blank", title: "Title", seq: 1, driven: true, owner: owner}

    {%{"ok" => %{"block" => state.next}},
     %{state | next: state.next + 1, blocks: Map.put(state.blocks, state.next, block)}}
  end

  defp answer(%{"op" => "blocks"}, state) do
    blocks = Enum.map(state.blocks, fn {id, block} -> Map.put(block, :block, id) end)
    {%{"ok" => %{"blocks" => blocks}}, state}
  end

  defp answer(%{"op" => "events", "block" => id, "after" => cursor}, state) do
    seq = state.blocks[id].seq

    events =
      cond do
        seq <= cursor -> []
        state[:event] -> [state.event]
        true -> [%{"seq" => seq, "type" => "loaded"}]
      end

    {%{"ok" => %{"events" => events, "next" => seq}}, state}
  end

  defp answer(%{"op" => "state", "block" => id}, state),
    do: {%{"ok" => Map.put(state.blocks[id], :shown, true)}, state}

  defp answer(%{"op" => "goto", "block" => id, "url" => url}, state) do
    next = update_in(state, [:blocks, id], &%{&1 | url: url, seq: &1.seq + 1})
    {%{"ok" => %{}}, next}
  end

  defp answer(%{"op" => "nav", "block" => id}, state),
    do: {%{"ok" => %{}}, update_in(state, [:blocks, id, :seq], &(&1 + 1))}

  defp answer(%{"op" => "snapshot"}, state),
    do:
      {%{
         "ok" => %{
           "text" => "[@e1] button Save",
           "url" => "https://example.com",
           "title" => "Title"
         }
       }, state}

  defp answer(%{"op" => "capture"}, state),
    do: {%{"ok" => %{"data" => Base.encode64("image")}}, state}

  defp answer(%{"op" => "eval", "function" => source, "args" => args}, state) do
    value =
      cond do
        String.contains?(source, "return (document.title") ->
          "Title"

        String.contains?(source, "elementFromPoint") ->
          %{"x" => 10, "y" => 20}

        String.contains?(source, "x:scrollX") ->
          %{"x" => 0, "y" => 123}

        String.contains?(source, "cloneNode") ->
          %{
            "url" => "https://example.com",
            "title" => "Title",
            "html" => "<p>hello</p>",
            "text" => "hello"
          }

        String.contains?(source, "e.options") ->
          Enum.at(args, 1)

        true ->
          true
      end

    {%{"ok" => %{"value" => value}}, state}
  end

  defp answer(%{"op" => "close", "block" => block}, state),
    do: {%{"ok" => %{}}, %{state | blocks: Map.delete(state.blocks, block)}}

  defp answer(_payload, state), do: {%{"ok" => %{"done" => true}}, state}

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
