defmodule LemonControlPlane.Methods.AgentContextOptionsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.Agent

  test "invalid coding context options fail before submission" do
    for options <- [%{"session_mode" => "unknown"}, %{"persona" => "false"}] do
      assert {:error, {:invalid_params, message}} =
               Agent.handle(Map.put(options, "prompt", "Inspect code"), %{})

      assert message =~ "session_mode must be coding|chat and persona a boolean"
    end
  end
end
