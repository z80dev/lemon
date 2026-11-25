defmodule LemonComputerUse.LemonOriginTest do
  # Lemon's own approval surfaces must never become computer-use targets, in
  # any loopback spelling, on any Lemon-owned port, or in an app that renders
  # them with a grant that outlives one action.
  use ExUnit.Case, async: false

  alias LemonComputerUse.Approval
  alias LemonCore.{ExecApprovals, ExecApprovalStore}
  alias LemonCore.Testing.AsyncHelpers

  defp origin_request(origin) do
    %{
      "mode" => "form",
      "message" => "Allow access to #{origin}?",
      "requestedSchema" => %{"type" => "object", "properties" => %{}},
      "_meta" => %{
        "codex_approval_kind" => "mcp_tool_call",
        "connector_id" => "browser-use",
        "tool_name" => "access_browser_origin",
        "origin" => origin
      }
    }
  end

  defp app_request(app) do
    %{
      "mode" => "form",
      "message" => "Allow Computer Use to use #{app}?",
      "requestedSchema" => %{"type" => "object", "properties" => %{}},
      "_meta" => %{
        "codex_approval_kind" => "mcp_tool_call",
        "connector_id" => "computer-use",
        "persist" => ["session", "always"],
        "tool_params" => %{"app" => app}
      }
    }
  end

  defp never_ask, do: %{approval_request_fun: fn _ -> flunk("must not ask") end}

  setup do
    saved =
      Map.new(~w(LEMON_BOT_PORT LEMON_BOT_PUBLIC_URL), fn key -> {key, System.get_env(key)} end)

    System.delete_env("LEMON_BOT_PUBLIC_URL")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "every loopback spelling and Lemon-owned port is a Lemon origin and is declined" do
    for origin <- [
          "http://127.0.0.2:4040",
          "http://[::ffff:7f00:1]:4040",
          "http://foo.localhost:4080",
          "http://LOCALHOST:4080",
          "http://127.0.0.1:4100",
          "http://127.0.0.1:4081",
          "http://localhost:4100",
          "http://[::1]:4100",
          "http://0.0.0.0:4100",
          "http://127.0.0.1",
          "http://2130706433:4100",
          "http://[::]:4100",
          "http://localhost.:4100",
          "http://[::ffff:127.0.0.1]:4100"
        ] do
      assert Approval.lemon_origin?(origin), origin

      assert %{action: "decline"} = Approval.answer(origin_request(origin), never_ask(), "id"),
             origin
    end

    refute Approval.lemon_origin?("https://example.com")
    refute Approval.lemon_origin?("http://localhost.example.com:4100")
  end

  test "a LEMON_BOT_PORT override is declined without LEMON_BOT_PUBLIC_URL" do
    System.put_env("LEMON_BOT_PORT", "4321")
    assert Approval.lemon_origin?("http://127.0.0.1:4321")
    assert Approval.lemon_origin?("http://localhost:4321")
  end

  test "the public URL saved in the installed backend unit is declined", %{} do
    home = Path.join(System.tmp_dir!(), "cua_home_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    dir = Path.join(home, ".lemon/run/service")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "lemon-bot.service.json"),
      Jason.encode!(%{
        "argv" => ["/usr/local/bin/lemon-bot", "--no-open"],
        "env" => %{"LEMON_BOT_PUBLIC_URL" => "https://mac.example.ts.net:8443/"}
      })
    )

    assert "https://mac.example.ts.net:8443" in LemonComputerUse.Config.declined_origins(
             home: home,
             os: {:unix, :freebsd}
           )
  end

  test "an origin at one of this machine's LAN addresses is declined" do
    {:ok, interfaces} = :inet.getifaddrs()

    lan =
      for {_name, opts} <- interfaces,
          {:addr, {a, _, _, _} = address} <- opts,
          a != 127,
          do: address |> :inet.ntoa() |> to_string()

    if lan == [], do: flunk("no non-loopback IPv4 interface to test with")

    for address <- lan do
      origin = "http://#{address}:4100"
      assert Approval.lemon_origin?(origin), origin
      assert %{action: "decline"} = Approval.answer(origin_request(origin), never_ask(), "id")
    end

    assert Approval.lemon_origin?("http://169.254.10.20:80")
    assert Approval.lemon_origin?("http://[fe80::1]:80")
  end

  test "a hostname resolving to a local address is declined; a public one is asked" do
    Application.put_env(:lemon_computer_use, :resolver, fn
      "rebind.example" -> [{93, 184, 216, 34}, {127, 0, 0, 1}]
      "mapped.example" -> [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]
      "public.example" -> [{93, 184, 216, 34}]
      "slow.example" -> Process.sleep(:infinity)
    end)

    on_exit(fn -> Application.delete_env(:lemon_computer_use, :resolver) end)

    assert Approval.lemon_origin?("https://rebind.example")
    assert Approval.lemon_origin?("https://mapped.example:8443")
    assert Approval.lemon_origin?("https://slow.example")
    refute Approval.lemon_origin?("https://public.example")

    assert %{action: "decline"} =
             Approval.answer(origin_request("https://rebind.example"), never_ask(), "id")
  end

  describe "native apps are once-only unless allowlisted" do
    setup do
      n = System.unique_integer([:positive])

      %{
        ctx: %{
          run_id: "cu_run_#{n}",
          session_id: "cu_session_#{n}",
          session_key: "agent:cuo:main:#{n}",
          agent_id: "cuo#{n}"
        },
        n: n
      }
    end

    defp policies do
      [:exec_approvals_policy, :exec_approvals_policy_agent, :exec_approvals_policy_session]
      |> Enum.flat_map(&LemonCore.Store.list/1)
      |> Enum.filter(&(inspect(&1) =~ "computer_use"))
    end

    defp start_answer(params, ctx, approval_id) do
      on_exit(fn -> ExecApprovalStore.delete_pending(approval_id) end)
      task = Task.async(fn -> Approval.answer(params, ctx, approval_id) end)

      assert :ok =
               AsyncHelpers.assert_eventually(
                 fn -> ExecApprovalStore.get_pending(approval_id) != nil end,
                 timeout: 2_000
               )

      task
    end

    test "a lasting decision for any app is limited to once and stores no grant", c do
      before = policies()

      for app <- ["com.google.Chrome", "com.apple.calculator"],
          scope <- [:approve_session, :approve_agent, :approve_global] do
        id = "cuo_#{c.n}_#{app}_#{scope}"
        task = start_answer(app_request(app), c.ctx, id)
        assert ExecApprovalStore.get_pending(id).once_only
        assert {:ok, %{decision: :approve_once}} = ExecApprovals.resolve(id, scope)
        # Accepted for this action only: nothing tells the runtime to persist.
        assert Task.await(task, 2_000) == %{action: "accept", content: %{}}
      end

      assert policies() == before

      # The next action asks again instead of being answered from a stored grant.
      next = "cuo_#{c.n}_next"
      task = start_answer(app_request("com.apple.calculator"), c.ctx, next)
      assert {:ok, _} = ExecApprovals.resolve(next, :deny)
      assert %{action: "decline"} = Task.await(task, 2_000)
    end

    test "a wildcard grant does not answer a once-only request", c do
      wildcard = %{tool: "computer_use", action_hash: :any, scope: :global, approved: true}
      ExecApprovalStore.put_global_policy("computer_use", :any, wildcard)

      on_exit(fn ->
        ExecApprovalStore.put_global_policy("computer_use", :any, %{wildcard | approved: false})
      end)

      id = "cuo_#{c.n}_wild"
      task = start_answer(app_request("com.apple.calculator"), c.ctx, id)
      assert {:ok, _} = ExecApprovals.resolve(id, :deny)
      assert %{action: "decline"} = Task.await(task, 2_000)
    end

    test "an allowlisted app keeps the decision's scope", c do
      Application.put_env(:lemon_computer_use, :lasting_grant_apps, ["com.apple.calculator"])
      on_exit(fn -> Application.delete_env(:lemon_computer_use, :lasting_grant_apps) end)

      id = "cuo_#{c.n}_allowed"
      task = start_answer(app_request("com.apple.calculator"), c.ctx, id)
      refute ExecApprovalStore.get_pending(id).once_only
      assert {:ok, _} = ExecApprovals.resolve(id, :approve_session)

      assert Task.await(task, 2_000) ==
               %{action: "accept", content: %{}, _meta: %{persist: "session"}}
    end

    # Seeds a global grant under the production policy key and proves it is
    # live: an ordinary (not once-only) request is answered from it at once.
    defp seed_global_grant(key, action) do
      ExecApprovalStore.put_global_policy("computer_use", key, %{
        tool: "computer_use",
        action_hash: key,
        scope: :global,
        approved: true
      })

      on_exit(fn ->
        ExecApprovalStore.put_global_policy("computer_use", key, %{approved: false})
      end)

      assert {:ok, :approved, :global} =
               ExecApprovals.request(%{tool: "computer_use", action: action})
    end

    defp assert_site_asks_once(origin, c) do
      Application.put_env(:lemon_computer_use, :resolver, fn _ -> [{93, 184, 216, 34}] end)
      on_exit(fn -> Application.delete_env(:lemon_computer_use, :resolver) end)
      before = policies()

      for scope <- [:approve_session, :approve_global] do
        id = "cuo_#{c.n}_site_#{scope}"
        task = start_answer(origin_request(origin), c.ctx, id)
        assert ExecApprovalStore.get_pending(id).once_only
        assert {:ok, %{decision: :approve_once}} = ExecApprovals.resolve(id, scope)
        assert Task.await(task, 2_000) == %{action: "accept", content: %{}}
      end

      assert policies() == before
    end

    test "an exact grant for the origin does not answer a website request", c do
      origin = "https://exact#{c.n}.example"
      action = %{"origin" => origin}
      seed_global_grant(ExecApprovals.hash_action(action), action)
      assert_site_asks_once(origin, c)
    end

    test "a wildcard grant does not answer a website request", c do
      seed_global_grant(:any, %{"origin" => "https://other#{c.n}.example"})
      assert_site_asks_once("https://wild#{c.n}.example", c)
    end
  end

  test "web clients of approval channels are declined without asking" do
    for origin <- [
          "https://web.telegram.org",
          "https://discord.com",
          "https://ptb.discord.com",
          "https://canary.discord.com",
          "https://app.slack.com",
          "https://acme.slack.com",
          "https://web.whatsapp.com",
          "https://mail.google.com"
        ] do
      assert %{action: "decline"} = Approval.answer(origin_request(origin), never_ask(), "id"),
             origin
    end

    assert Approval.lemon_origin?("https://WEB.Telegram.org.")
    refute Approval.approval_web_client?("nottelegram.org")
    refute Approval.approval_web_client?("telegram.org.evil.example")
  end
end
