defmodule LemonAi.Auth.GitHubCopilotDevicePollTest do
  # Swaps Req's global default plug.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.GitHubCopilotOAuth

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    {:ok, polls} = Agent.start_link(fn -> ~w(authorization_pending slow_down) end)
    Req.Test.stub(__MODULE__, &github(&1, polls))
    :ok
  end

  test "device polling uses the injected sleep, honors slow_down and never blocks" do
    test_pid = self()

    assert {:ok, secret} =
             GitHubCopilotOAuth.login_device_flow(
               enable_models: false,
               on_auth: fn _url, _instructions -> :ok end,
               sleep: &send(test_pid, {:slept, &1})
             )

    assert secret["refresh_token"] == "gho_github_token"
    assert secret["access_token"] == "copilot-token"
    assert_received {:slept, 5_000}
    assert_received {:slept, 10_000}
    refute_received {:slept, _}
  end

  test "an expired device code stops polling" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/login/device/code" -> Req.Test.json(conn, device())
        "/login/oauth/access_token" -> Req.Test.json(conn, %{"error" => "expired_token"})
      end
    end)

    assert {:error, :device_code_expired} =
             GitHubCopilotOAuth.login_device_flow(
               enable_models: false,
               on_auth: fn _url, _instructions -> :ok end,
               sleep: fn _ -> flunk("must not sleep after a terminal error") end
             )
  end

  defp github(conn, polls) do
    case conn.request_path do
      "/login/device/code" ->
        Req.Test.json(conn, device())

      "/login/oauth/access_token" ->
        case Agent.get_and_update(polls, fn
               [next | rest] -> {next, rest}
               [] -> {nil, []}
             end) do
          nil -> Req.Test.json(conn, %{"access_token" => "gho_github_token"})
          error -> Req.Test.json(conn, %{"error" => error})
        end

      "/copilot_internal/v2/token" ->
        Req.Test.json(conn, %{
          "token" => "copilot-token",
          "expires_at" => System.system_time(:second) + 3_600
        })
    end
  end

  defp device do
    %{
      "device_code" => "device-code",
      "user_code" => "ABCD-1234",
      "verification_uri" => "https://github.com/login/device",
      "interval" => 5,
      "expires_in" => 900
    }
  end
end
