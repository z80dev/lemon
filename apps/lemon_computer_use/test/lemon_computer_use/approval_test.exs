defmodule LemonComputerUse.ApprovalTest do
  use ExUnit.Case, async: false

  alias LemonComputerUse.Approval

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "mode" => "form",
        "message" => "Allow Computer Use to use Calculator?",
        "requestedSchema" => %{"type" => "object", "properties" => %{}},
        "_meta" => %{
          "codex_approval_kind" => "mcp_tool_call",
          "connector_id" => "computer-use",
          "persist" => ["session", "always"],
          "tool_params" => %{"app" => "com.apple.calculator"}
        }
      },
      overrides
    )
  end

  test "recognizes only well-formed native-app requests" do
    assert {:ok, "com.apple.calculator", "Allow Computer Use to use Calculator?",
            ["session", "always"]} =
             Approval.native_app_request(request())

    assert :error = Approval.native_app_request(request(%{"mode" => "url"}))
    assert :error = Approval.native_app_request(request(%{"message" => ""}))

    assert :error =
             Approval.native_app_request(
               request(%{
                 "requestedSchema" => %{"type" => "object", "properties" => %{"x" => %{}}}
               })
             )

    assert :error =
             Approval.native_app_request(
               request(%{
                 "_meta" => %{
                   "connector_id" => "computer-use",
                   "tool_name" => "access_browser_origin"
                 }
               })
             )
  end

  test "anything else is cancelled without asking" do
    ask = fn _ -> flunk("must not ask") end

    assert %{action: "cancel"} =
             Approval.answer(%{"mode" => "url"}, %{approval_request_fun: ask}, "id")
  end

  test "Lemon's own apps are hosts, other apps are not" do
    assert Approval.lemon_host?("org.lemonbot.mac")
    assert Approval.lemon_host?("Lemon Bot")
    refute Approval.lemon_host?("com.apple.calculator")
  end

  test "approval failures and malformed replies fail closed" do
    raising = fn _ -> raise "store down" end
    odd = fn _ -> :maybe end

    assert %{action: "cancel"} =
             Approval.answer(request(), %{approval_request_fun: raising}, "id")

    assert %{action: "cancel"} = Approval.answer(request(), %{approval_request_fun: odd}, "id")
  end

  test "the Lemon scope decides how long the runtime keeps the grant" do
    answer = fn reply ->
      Approval.answer(request(), %{approval_request_fun: fn _ -> reply end}, "id")
    end

    assert answer.({:ok, :approved, :approve_once}) == %{action: "accept", content: %{}}

    for scope <- [:approve_session, :approve_agent, :approve_global, :session, :global] do
      assert answer.({:ok, :approved, scope}) ==
               %{action: "accept", content: %{}, _meta: %{persist: "session"}}
    end

    assert answer.({:ok, :approved, :forever}) == %{action: "cancel"}
    assert answer.({:ok, :denied}) == %{action: "decline"}
    assert answer.({:error, :timeout}) == %{action: "cancel"}
  end

  test "long runtime messages are bounded in the approval rationale" do
    parent = self()

    capture = fn req ->
      send(parent, {:rationale, req.rationale})
      {:ok, :approved, :approve_session}
    end

    long = String.duplicate("x", 2_000)

    assert %{action: "accept", content: %{}} =
             Approval.answer(
               request(%{"message" => long}),
               %{approval_request_fun: capture},
               "id"
             )

    assert_received {:rationale, rationale}
    assert byte_size(rationale) < 600
  end

  defp origin_request(origin, overrides \\ %{}) do
    Map.merge(
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
      },
      overrides
    )
  end

  test "recognizes only exact http(s) website origins" do
    assert {:ok, "https://example.com", _} =
             Approval.browser_origin_request(origin_request("https://example.com"))

    assert {:ok, "http://[::1]:8080", _} =
             Approval.browser_origin_request(origin_request("http://[::1]:8080"))

    for bad <- [
          "https://example.com/",
          "https://example.com:443",
          "https://user@example.com",
          "https://example.com/path",
          "file:///etc/passwd",
          "chrome://settings"
        ] do
      assert :error = Approval.browser_origin_request(origin_request(bad)), bad
    end

    assert :error =
             Approval.browser_origin_request(
               origin_request("https://example.com", %{"mode" => "url"})
             )
  end

  test "any approval scope accepts a website; denial declines; Lemon's own origins are declined" do
    answer = fn origin, reply ->
      Approval.answer(origin_request(origin), %{approval_request_fun: fn _ -> reply end}, "id")
    end

    assert answer.("https://example.com", {:ok, :approved, :approve_once}) ==
             %{action: "accept", content: %{}}

    assert answer.("https://example.com", {:ok, :approved, :approve_global}) ==
             %{action: "accept", content: %{}}

    assert answer.("https://example.com", {:ok, :approved, :forever}) == %{action: "cancel"}
    assert answer.("https://example.com", {:ok, :denied}) == %{action: "decline"}

    ask = fn _ -> flunk("must not ask for Lemon's own surfaces") end

    assert %{action: "decline"} =
             Approval.answer(
               origin_request("http://127.0.0.1:#{LemonCore.Runtime.Env.control_port()}"),
               %{approval_request_fun: ask},
               "id"
             )
  end

  test "the Lemon Bot web origin and configured origins are declined without asking" do
    saved = System.get_env("LEMON_BOT_PUBLIC_URL")

    on_exit(fn ->
      if saved,
        do: System.put_env("LEMON_BOT_PUBLIC_URL", saved),
        else: System.delete_env("LEMON_BOT_PUBLIC_URL")

      System.delete_env("LEMON_COMPUTER_USE_DECLINED_ORIGINS")
      Application.delete_env(:lemon_computer_use, :declined_origins)
    end)

    System.put_env("LEMON_BOT_PUBLIC_URL", "https://bot.tailnet-example.ts.net/")

    System.put_env(
      "LEMON_COMPUTER_USE_DECLINED_ORIGINS",
      "https://lemon.example:8443/app, not a url"
    )

    Application.put_env(:lemon_computer_use, :declined_origins, ["http://[::1]:9000"])

    assert LemonComputerUse.Config.declined_origins() == [
             "https://bot.tailnet-example.ts.net",
             "https://lemon.example:8443",
             "http://[::1]:9000"
           ]

    ask = fn _ -> flunk("must not ask for Lemon's own surfaces") end

    for origin <- [
          "https://bot.tailnet-example.ts.net",
          "https://lemon.example:8443",
          "http://[::1]:9000",
          "http://127.0.0.1:4081"
        ] do
      assert %{action: "decline"} =
               Approval.answer(origin_request(origin), %{approval_request_fun: ask}, "id"),
             origin
    end

    approve = fn _ -> {:ok, :approved, :approve_once} end

    assert %{action: "accept"} =
             Approval.answer(
               origin_request("https://lemon.example"),
               %{approval_request_fun: approve},
               "id"
             )
  end

  describe "an owner that ends expires its untimed approval" do
    alias LemonCore.{ExecApprovalExpiry, ExecApprovals, ExecApprovalStore, RunStore}
    alias LemonCore.Testing.AsyncHelpers

    setup do
      n = System.unique_integer([:positive])
      approval_id = "cu_approval_#{n}"
      on_exit(fn -> ExecApprovalStore.delete_pending(approval_id) end)

      %{
        approval_id: approval_id,
        ctx: %{
          run_id: "cu_run_#{n}",
          session_id: "cu_session_#{n}",
          session_key: "agent:cu:main:#{n}",
          agent_id: "cu"
        }
      }
    end

    defp ask_for_real(params, ctx, approval_id) do
      task = Task.async(fn -> Approval.answer(params, ctx, approval_id) end)

      assert :ok =
               AsyncHelpers.assert_eventually(
                 fn -> ExecApprovalStore.get_pending(approval_id) != nil end,
                 timeout: 2_000
               )

      task
    end

    defp assert_refused(approval_id) do
      for decision <- [:approve_once, :approve_session, :approve_agent, :approve_global] do
        assert {:error, :expired} = ExecApprovals.resolve(approval_id, decision)
      end

      assert {:ok, nil} = ExecApprovalStore.fetch_pending(approval_id)
    end

    test "a run ending declines the app request and refuses a late answer", c do
      task = ask_for_real(request(), c.ctx, c.approval_id)

      pending = ExecApprovalStore.get_pending(c.approval_id)
      assert pending.tool == "computer_use"
      assert pending.expires_at_ms == nil

      assert :ok =
               RunStore.finalize(c.ctx.run_id, %{
                 completed: %{ok: false, error: :aborted},
                 prompt: "use calculator",
                 session_key: c.ctx.session_key
               })

      assert %{action: "decline"} = Task.await(task, 2_000)
      assert_refused(c.approval_id)
    end

    test "a session ending declines the website request and refuses a late answer", c do
      task = ask_for_real(origin_request("https://example.com"), c.ctx, c.approval_id)

      assert ExecApprovalStore.get_pending(c.approval_id).action == %{
               "origin" => "https://example.com"
             }

      assert :ok = ExecApprovalExpiry.session_ended(c.ctx.session_id)

      assert %{action: "decline"} = Task.await(task, 2_000)
      assert_refused(c.approval_id)
    end

    test "another run's approval is unaffected", c do
      task = ask_for_real(request(), c.ctx, c.approval_id)

      assert {:ok, 0} = ExecApprovals.expire_owner({:run, c.ctx.run_id <> "_other"})
      assert %{id: _} = ExecApprovalStore.get_pending(c.approval_id)

      assert {:ok, %{outcome: :approved}} = ExecApprovals.resolve(c.approval_id, :approve_once)
      assert %{action: "accept", content: %{}} = Task.await(task, 2_000)
    end
  end
end
