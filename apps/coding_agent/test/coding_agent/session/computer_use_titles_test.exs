defmodule CodingAgent.Session.ComputerUseTitlesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Presentation

  test "computer-use calls are titled by the runtime's title or the first code line" do
    assert Presentation.tool_title("cua_js", %{"code" => "x", "title" => "Open Calculator"}) ==
             "computer use: Open Calculator"

    assert Presentation.tool_title("cua_js", %{"code" => "await cua.getState();\nmore"}) ==
             "computer use: await cua.getState();"

    assert Presentation.tool_title("cua_js_reset", %{}) == "computer use reset"
  end

  test "computer-use approvals name the app or site" do
    assert %{title: "computer use app: com.apple.calculator", kind: :approval} =
             Presentation.approval_action(
               {:approval_request, "a1",
                %{tool: "computer_use", action: %{"app" => "com.apple.calculator"}}}
             )

    assert %{title: "computer use site: https://example.com"} =
             Presentation.approval_action(
               {:approval_request, "a2",
                %{tool: "computer_use", action: %{"origin" => "https://example.com"}}}
             )
  end

  test "an approval expired by its ended run completes as not ok and says why" do
    pending = %{tool: "computer_use", action: %{"app" => "com.apple.calculator"}}

    for decision <- [:expired, "expired"] do
      assert %{
               kind: :approval,
               phase: :completed,
               ok: false,
               message: "expired because its run ended",
               detail: %{decision: ^decision}
             } = Presentation.approval_action({:approval_resolved, "a3", decision, pending})
    end
  end
end
