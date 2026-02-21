defmodule CodingAgent.Wasm.PolicyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.Policy

  describe "capability_requires_approval?/1" do
    test "returns true when http is true (atom key)" do
      assert Policy.capability_requires_approval?(%{http: true})
    end

    test "returns true when tool_invoke is true (atom key)" do
      assert Policy.capability_requires_approval?(%{tool_invoke: true})
    end

    test "returns false when both are false" do
      refute Policy.capability_requires_approval?(%{http: false, tool_invoke: false})
    end

    test "returns false with nil" do
      refute Policy.capability_requires_approval?(nil)
    end

    test "returns true with string key http" do
      assert Policy.capability_requires_approval?(%{"http" => true})
    end

    test "returns true with string key tool_invoke" do
      assert Policy.capability_requires_approval?(%{"tool_invoke" => true})
    end

    test "returns false with empty map" do
      refute Policy.capability_requires_approval?(%{})
    end
  end

  describe "requires_approval?/3" do
    test "returns false with no capabilities" do
      metadata = %{capabilities: %{http: false, tool_invoke: false}}

      refute Policy.requires_approval?(nil, "my_tool", metadata)
    end

    test "returns true with http capability by default" do
      metadata = %{capabilities: %{http: true}}

      assert Policy.requires_approval?(nil, "my_tool", metadata)
    end

    test "returns true when policy sets approval to :always" do
      policy = %{approvals: %{"my_tool" => :always}}
      metadata = %{capabilities: %{}}

      assert Policy.requires_approval?(policy, "my_tool", metadata)
    end

    test "returns false when policy sets approval to :never even with http capability" do
      policy = %{approvals: %{"my_tool" => :never}}
      metadata = %{capabilities: %{http: true}}

      refute Policy.requires_approval?(policy, "my_tool", metadata)
    end

    test "returns false with non-binary tool_name" do
      refute Policy.requires_approval?(nil, :not_a_string, %{})
    end

    test "returns false with non-map metadata" do
      refute Policy.requires_approval?(nil, "my_tool", "not a map")
    end

    test "returns false with non-binary tool_name and non-map metadata" do
      refute Policy.requires_approval?(nil, 123, :invalid)
    end
  end
end
