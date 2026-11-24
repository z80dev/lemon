defmodule LemonBrowser.LocalServerDeadlineTest do
  @moduledoc """
  A browser action that may have taken effect is reported as
  `{:error, :outcome_unknown}` and reaches the driver exactly once: neither
  `LocalServer` nor the `LemonBrowser` facade re-sends it. Read-only requests
  keep plain timeout/exit errors.
  """
  use ExUnit.Case, async: false

  alias LemonBrowser.LocalServer

  @moduletag :browser_local_server
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    if is_nil(System.find_executable("node")), do: raise("node is required")

    log = Path.join(tmp, "requests.log")
    driver = Path.join(tmp, "driver.mjs")

    # Logs every request line it reads. `args.mode` selects the behaviour:
    # `hang` never answers, `exit` ends the driver, `code` answers with that
    # driver error code; anything else succeeds.
    File.write!(driver, """
    import fs from 'node:fs';
    let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      buffer += chunk;
      while (true) {
        const index = buffer.indexOf('\\n');
        if (index < 0) break;
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        fs.appendFileSync(#{inspect(log)}, line + '\\n');
        const request = JSON.parse(line);
        const mode = request.args && request.args.mode;
        if (mode === 'hang') continue;
        if (mode === 'exit') process.exit(1);
        const reply = mode
          ? {id: request.id, ok: false, code: mode, error: 'driver says ' + mode}
          : {id: request.id, ok: true, result: {deadlineAtMs: request.deadlineAtMs}};
        process.stdout.write(JSON.stringify(reply) + '\\n');
      }
    });
    """)

    {:ok, pid} = LocalServer.start_link(name: nil, driver_path: driver)
    on_exit(fn -> LocalServer.stop(pid) end)
    {:ok, server: pid, log: log}
  end

  test "sends an absolute deadline the driver must not start after", %{server: server} do
    before = System.os_time(:millisecond)

    assert {:ok, %{"deadlineAtMs" => deadline}} =
             LocalServer.request(server, "browser.tabs", %{}, 5_000)

    assert deadline >= before + 5_000
    assert deadline <= System.os_time(:millisecond) + 5_000
  end

  test "an unanswered click is :outcome_unknown and is sent to the driver once", %{
    server: server,
    log: log
  } do
    assert {:error, :outcome_unknown} =
             LemonBrowser.request(
               "browser.click",
               %{"selector" => "#buy", "mode" => "hang"},
               100,
               backend: :local,
               server: server
             )

    assert [click] = requests(log)
    assert click["method"] == "browser.click"
    assert LocalServer.status(server).last_error.category == "outcome_unknown"
  end

  test "an unanswered read-only request is a plain timeout", %{server: server} do
    assert {:error, "Browser request timed out"} =
             LocalServer.request(server, "browser.snapshot", %{"mode" => "hang"}, 100)
  end

  test "driver codes map to outcome_unknown, not-started and timeout replies", %{
    server: server,
    log: log
  } do
    assert {:error, :outcome_unknown} =
             LocalServer.request(server, "browser.type", %{"mode" => "outcome_unknown"}, 5_000)

    assert {:error, "Browser request timed out before it started"} =
             LocalServer.request(server, "browser.click", %{"mode" => "not_started"}, 5_000)

    assert {:error, "Browser request timed out"} =
             LocalServer.request(server, "browser.snapshot", %{"mode" => "timeout"}, 5_000)

    assert length(requests(log)) == 3
  end

  test "a click in flight when the driver exits is :outcome_unknown; a read is not", %{
    server: server
  } do
    assert {:error, :outcome_unknown} =
             LocalServer.request(server, "browser.click", %{"mode" => "exit"}, 5_000)

    assert {:error, "Local browser driver exited"} =
             LocalServer.request(server, "browser.getContent", %{"mode" => "exit"}, 5_000)
  end

  test "classifies read-only methods like the driver" do
    for method <- ~w(browser.tabs browser.screenshot browser.snapshot browser.getContent
                     browser.getCookies browser.waitForSelector browser.cdp browser.events) do
      assert LocalServer.read_only_method?(method, %{})
    end

    for method <- ~w(browser.click browser.type browser.press browser.navigate browser.back
                     browser.selectOption browser.setInputFiles browser.download browser.hover
                     browser.scroll browser.evaluate browser.setCookies browser.clearState
                     browser.tabOpen browser.tabActivate browser.tabClose browser.future) do
      refute LocalServer.read_only_method?(method, %{})
    end

    refute LocalServer.read_only_method?("browser.events", %{"clear" => true})
  end

  defp requests(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
