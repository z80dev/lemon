defmodule LemonComputerUse.ApprovalTest do
  use ExUnit.Case, async: true

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
end
