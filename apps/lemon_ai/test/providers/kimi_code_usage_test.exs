defmodule LemonAi.Providers.KimiCodeUsageTest do
  use ExUnit.Case, async: true

  alias LemonAi.Providers.KimiCodeUsage

  # Shape returned by GET https://api.kimi.com/coding/v1/usages on 2026-11-11.
  @live_body %{
    "limits" => [
      %{
        "window" => %{"duration" => 300, "timeUnit" => "TIME_UNIT_MINUTE"},
        "detail" => %{
          "limit" => "100",
          "used" => "76",
          "resetTime" => "2026-11-12T04:34:23.135312Z"
        }
      }
    ],
    "usages" => %{
      "limit_5h" => %{"used_ratio" => 0.76, "reset_time" => "2026-11-12T04:34:22Z"},
      "limit_month_total" => %{"used_ratio" => 0.5697, "reset_time" => "2026-11-16T00:00:00Z"},
      "limit_month_code" => %{"used_ratio" => 0.5885, "reset_time" => "2026-11-16T00:00:00Z"}
    }
  }

  defp jwt(claims) do
    "eyJhbGciOiJub25lIn0.#{claims |> Jason.encode!() |> Base.url_encode64(padding: false)}.sig"
  end

  defp stub(fun) do
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, fun)
    [req_options: [plug: {Req.Test, name}]]
  end

  test "reads the usages endpoint with the bearer token and fingerprint and summarizes it" do
    token = jwt(%{"exp" => System.system_time(:second) + 600})
    test_pid = self()

    opts =
      stub(fn conn ->
        send(test_pid, {:request, conn.method, conn.host, conn.request_path, conn.req_headers})
        Req.Test.json(conn, @live_body)
      end)

    assert {:ok, windows} = KimiCodeUsage.fetch(token, opts)

    assert_received {:request, "GET", "api.kimi.com", "/coding/v1/usages", headers}
    headers = Map.new(headers)
    assert headers["authorization"] == "Bearer " <> token
    assert headers["x-msh-platform"] == "kimi_cli"
    assert headers["user-agent"] == "KimiCLI/" <> headers["x-msh-version"]

    assert KimiCodeUsage.format(windows) ==
             "5h window: 76% used, resets 04:34Z; month: 57% used; month (coding): 59% used"
  end

  test "limits fill windows the usages map lacks" do
    body = %{
      "limits" => [
        %{
          "window" => %{"duration" => 300, "timeUnit" => "TIME_UNIT_MINUTE"},
          "detail" => %{
            "limit" => "200",
            "remaining" => "50",
            "resetTime" => "2026-11-12T04:34:23Z"
          }
        },
        %{
          "window" => %{"duration" => 7, "timeUnit" => "TIME_UNIT_DAY"},
          "detail" => %{"limit" => 10, "used" => 20}
        },
        %{"window" => %{"duration" => 60, "timeUnit" => "TIME_UNIT_MINUTE"}, "detail" => %{}}
      ]
    }

    assert [
             %{id: "5h", used_fraction: 0.75, resets_at: ~U[2026-11-12 04:34:23Z]},
             %{id: "7d", label: "7d window", used_fraction: 1.0}
           ] = KimiCodeUsage.parse(body)
  end

  test "an expired token is not sent" do
    opts = stub(fn _conn -> flunk("expired token must not be sent") end)
    token = jwt(%{"exp" => System.system_time(:second) - 1})
    assert {:error, :token_expired} = KimiCodeUsage.fetch(token, opts)
  end

  test "failures report only a status or reason" do
    token = jwt(%{"exp" => System.system_time(:second) + 600})

    opts =
      stub(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "secret-detail"})
      end)

    assert {:error, {:http_error, 401}} = KimiCodeUsage.fetch(token, opts)

    opts = stub(fn conn -> Req.Test.json(conn, %{"usages" => %{}}) end)
    assert {:error, :invalid_usage_response} = KimiCodeUsage.fetch(token, opts)

    opts = stub(&Req.Test.transport_error(&1, :timeout))
    assert {:error, {:transport_error, :timeout}} = KimiCodeUsage.fetch(token, opts)
  end
end
