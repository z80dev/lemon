defmodule LemonComputerUse.ChromeLiveSmokeTest do
  @moduledoc """
  Opens a local test page in Chrome through `cua_js` with the browser surface
  (`lcu --chrome`) and the real Lemon approval plane, reads it and closes the
  tab. Excluded by default. Needs LCU's Chrome relay (`lcu browser install`)
  and the official ChatGPT extension connected through it:

      scripts/test path apps/lemon_computer_use/test --include computer_use_chrome_live
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonComputerUse.Tools.Js

  @moduletag :computer_use_chrome_live
  @moduletag timeout: 180_000

  @marker "lemon-cua-chrome-smoke"

  setup do
    Application.put_env(:lemon_computer_use, :chrome, true)
    on_exit(fn -> Application.delete_env(:lemon_computer_use, :chrome) end)

    dir = Path.join(System.tmp_dir!(), "#{@marker}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "index.html"),
      "<!doctype html><title>#{@marker}</title><h1 id=\"m\">#{@marker}</h1>"
    )

    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, httpd} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"lemon-cua-smoke",
        server_root: String.to_charlist(dir),
        document_root: String.to_charlist(dir),
        bind_address: {127, 0, 0, 1}
      )

    port = :httpd.info(httpd)[:port]

    on_exit(fn ->
      :inets.stop(:httpd, httpd)
      File.rm_rf(dir)
    end)

    start_supervised!({LemonComputerUse.Server, []})
    test_pid = self()
    origin = "http://127.0.0.1:#{port}"
    approver = spawn_link(fn -> approver(test_pid, origin) end)
    receive do: ({:approver_ready, ^approver} -> :ok)
    %{origin: origin}
  end

  # Stands in for the operator: approves exactly the test origin.
  defp approver(test_pid, origin) do
    LemonCore.Bus.subscribe("exec_approvals")
    send(test_pid, {:approver_ready, self()})
    approve_loop(test_pid, origin)
  end

  defp approve_loop(test_pid, origin) do
    receive do
      %LemonCore.Event{type: :approval_requested, payload: %{approval_id: id, pending: pending}} ->
        decision =
          if pending.tool == "computer_use" and pending.action == %{"origin" => origin},
            do: :approve_session,
            else: :deny

        send(test_pid, {:approval_requested, pending.action})
        LemonCore.ExecApprovals.resolve(id, decision)
        approve_loop(test_pid, origin)

      _other ->
        approve_loop(test_pid, origin)
    end
  end

  defp text(%AgentToolResult{content: content}) do
    content |> Enum.filter(&match?(%TextContent{}, &1)) |> Enum.map_join("\n", & &1.text)
  end

  test "reads a local page in a new Chrome tab and closes it", %{origin: origin} do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    js =
      Js.tool("/tmp",
        session_id: "lemon-cua-chrome-" <> nonce,
        run_id: "lemon-cua-chrome-run-" <> nonce
      )

    call = fn code ->
      js.execute.("call-#{System.unique_integer([:positive])}", %{"code" => code}, nil, nil)
    end

    # First call: exactly one API call, as the runtime's guide requires.
    selected = call.("const browser = await cua.getBrowser();")
    assert %AgentToolResult{is_error: false} = selected, text(selected)

    opened =
      call.(
        "const tab = await cua.createBrowserTab(browser.browserId, " <>
          Jason.encode!(origin <> "/index.html") <> ");"
      )

    assert %AgentToolResult{is_error: false, trust: :untrusted} = opened, text(opened)

    read = call.("await tab.getAXState({ disableDiffing: true });")
    assert %AgentToolResult{is_error: false} = read
    assert text(read) =~ @marker

    assert_received {:approval_requested, %{"origin" => ^origin}}

    assert %AgentToolResult{is_error: false} = call.("await tab.close?.();")
  end
end
