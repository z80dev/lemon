defmodule LemonControlPlane.Protocol.ProfilePayloadLimitsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Frames

  test "rich profile execution frames retain full native tool grants" do
    names = Enum.map(1..16_384, &"mcp_tool_#{&1}")
    policy = %{"require_approval" => names}

    for method <- [
          "profiles.create",
          "profiles.update",
          "profiles.clone",
          "chat.send",
          "agent",
          "node.invoke.result"
        ] do
      params = %{"toolPolicy" => policy}

      assert {:ok, %{params: ^params}} =
               Frames.parse(frame(method, params), max_payload: 16_777_216)
    end

    params = %{"method" => "coding_agent.run", "args" => %{"toolPolicy" => policy}}

    assert {:ok, %{params: ^params}} =
             Frames.parse(frame("node.invoke", params), max_payload: 16_777_216)
  end

  test "unrelated methods and explicit smaller budgets retain their ceilings" do
    params = %{"values" => Enum.to_list(1..16_384)}
    assert {:error, _} = Frames.parse(frame("health", params), max_payload: 16_777_216)

    assert {:error, _} =
             Frames.parse(frame("node.invoke", Map.put(params, "method", "other.run")),
               max_payload: 16_777_216
             )

    assert {:error, _} =
             Frames.parse(frame("chat.send", params), max_payload: 16_777_216, max_items: 10_000)

    assert {:error, _} = Frames.parse(frame("chat.send", params), max_payload: 128)
    assert {:ok, _} = Frames.parse(frame("health", %{}), max_payload: 128)
  end

  defp frame(method, params) do
    Jason.encode!(%{
      "type" => "req",
      "id" => "payload-budget",
      "method" => method,
      "params" => params
    })
  end
end
