defmodule LemonCore.Doctor.LiveChecksTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Check, Connectivity, LiveChecks, Report}

  defmodule RegisteredProbe do
    def run(_), do: []

    def live_checks(opts) do
      [{"test.live", fn -> Keyword.fetch!(opts, :probe).() end}]
    end
  end

  test "without --live doctor never invokes a live callback" do
    previous = Application.get_env(:lemon_core, :doctor_checks)
    Application.put_env(:lemon_core, :doctor_checks, [RegisteredProbe])
    on_exit(fn -> Application.put_env(:lemon_core, :doctor_checks, previous) end)
    parent = self()

    opts = [
      probe: fn ->
        send(parent, :http_called)
        Check.fail("test.live", "auth rejected")
      end
    ]

    offline = Doctor.report(opts)
    refute Enum.any?(offline.checks, &(&1.name == "test.live"))
    refute_received :http_called

    live = Doctor.report(Keyword.put(opts, :live, true))
    assert_received :http_called
    assert Enum.any?(live.checks, &(&1.name == "test.live" and &1.status == :fail))
    refute Report.ok?(live)
    assert Report.to_json(live) =~ "test.live"
  end

  test "concurrent checks share an overall deadline and hung tasks are killed" do
    parent = self()

    jobs =
      for index <- 1..3 do
        {"live.#{index}",
         fn ->
           send(parent, {:started, self()})
           Process.sleep(:infinity)
         end}
      end

    start = System.monotonic_time(:millisecond)
    results = LiveChecks.run(jobs, live_overall_timeout_ms: 50)
    assert System.monotonic_time(:millisecond) - start < 500
    assert Enum.all?(results, &(&1.status == :fail and &1.message =~ "timed out"))

    for _ <- 1..3 do
      assert_received {:started, pid}
      refute Process.alive?(pid)
    end
  end

  test "live output is redacted and exception details are discarded" do
    jobs = [
      {"redacted", fn -> Check.pass("redacted", "api_key=sk-fake_secret_12345678") end},
      {"exception", fn -> raise "https://secret.invalid/?token=raw-secret" end}
    ]

    results = LiveChecks.run(jobs)
    assert hd(results).message =~ "[REDACTED]"
    refute inspect(results) =~ "sk-fake"
    refute inspect(results) =~ "secret.invalid"
  end

  for {response, expected} <- [
        {{:ok, {{~c"HTTP/1.1", 401, ~c"Unauthorized"}, [], "token=fake-token"}}, :unauthorized},
        {{:ok, {{~c"HTTP/1.1", 503, ~c"Unavailable"}, [], "fake-token"}}, {:http_status, 503}},
        {{:error, :timeout}, :timeout},
        {{:error, {:failed_connect, "secret URL"}}, :unreachable}
      ] do
    test "HTTP failure is safely classified as #{inspect(expected)}" do
      response = unquote(Macro.escape(response))

      assert {:error, unquote(Macro.escape(expected))} =
               Connectivity.get("https://example.invalid/models", %{},
                 http_get: fn :get, _, opts, _ ->
                   assert opts[:timeout] == 5_000
                   assert opts[:connect_timeout] == 5_000
                   refute opts[:autoredirect]
                   response
                 end
               )
    end
  end
end
