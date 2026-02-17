defmodule CodingAgent.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ToolPolicy

  describe "from_profile/1" do
    test "full_access allows all tools" do
      policy = ToolPolicy.from_profile(:full_access)

      assert policy.allow == :all
      assert policy.deny == []
      assert ToolPolicy.allowed?(policy, "write")
      assert ToolPolicy.allowed?(policy, "bash")
      assert ToolPolicy.allowed?(policy, "read")
    end

    test "read_only only allows read tools" do
      policy = ToolPolicy.from_profile(:read_only)

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "grep")
      assert ToolPolicy.allowed?(policy, "find")
      refute ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "bash")
    end

    test "minimal_core allows core tools and excludes redundant ones" do
      policy = ToolPolicy.from_profile(:minimal_core)

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "memory_topic")
      assert ToolPolicy.allowed?(policy, "write")
      assert ToolPolicy.allowed?(policy, "patch")
      assert ToolPolicy.allowed?(policy, "todo")
      assert ToolPolicy.allowed?(policy, "task")
      assert ToolPolicy.allowed?(policy, "agent")
      assert ToolPolicy.allowed?(policy, "extensions_status")

      refute ToolPolicy.allowed?(policy, "restart")
      refute ToolPolicy.allowed?(policy, "multiedit")
      refute ToolPolicy.allowed?(policy, "glob")
      refute ToolPolicy.allowed?(policy, "todoread")
      refute ToolPolicy.allowed?(policy, "todowrite")
    end

    test "safe_mode denies dangerous tools" do
      policy = ToolPolicy.from_profile(:safe_mode)

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "grep")
      refute ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "edit")
      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "exec")
    end

    test "subagent_restricted denies dangerous tools and requires approval" do
      policy = ToolPolicy.from_profile(:subagent_restricted)

      refute ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "agent")
      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "edit")
    end

    test "no_external denies external tools" do
      policy = ToolPolicy.from_profile(:no_external)

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "webfetch")
      refute ToolPolicy.allowed?(policy, "websearch")
    end

    test "unknown profile defaults to full_access" do
      policy = ToolPolicy.from_profile(:unknown_profile)

      assert policy.allow == :all
    end
  end

  describe "custom/1" do
    test "creates custom policy with allow list" do
      policy = ToolPolicy.custom(allow: ["read", "write"])

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "bash")
    end

    test "creates custom policy with deny list" do
      policy = ToolPolicy.custom(deny: ["bash", "exec"])

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "exec")
    end

    test "creates custom policy with approval requirements" do
      policy = ToolPolicy.custom(require_approval: ["write", "edit"])

      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "read")
    end

    test "creates custom policy with NO_REPLY" do
      policy = ToolPolicy.custom(no_reply: true)

      assert ToolPolicy.no_reply?(policy)
    end
  end

  describe "allowed?/2" do
    test "respects allow list" do
      policy = %{allow: ["read", "write"], deny: []}

      assert ToolPolicy.allowed?(policy, "read")
      assert ToolPolicy.allowed?(policy, "write")
      refute ToolPolicy.allowed?(policy, "bash")
    end

    test "respects deny list over allow all" do
      policy = %{allow: :all, deny: ["bash", "exec"]}

      assert ToolPolicy.allowed?(policy, "read")
      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "exec")
    end

    test "empty allow list denies all" do
      policy = %{allow: [], deny: []}

      refute ToolPolicy.allowed?(policy, "read")
      refute ToolPolicy.allowed?(policy, "write")
    end
  end

  describe "denial_reason/2" do
    test "returns reason for denied tool" do
      policy = %{allow: ["read"], deny: ["bash"]}

      assert ToolPolicy.denial_reason(policy, "write") == "Tool 'write' not in allowed list"
      assert ToolPolicy.denial_reason(policy, "bash") == "Tool 'bash' is in deny list"
    end

    test "returns nil for allowed tool" do
      policy = %{allow: :all, deny: []}

      assert ToolPolicy.denial_reason(policy, "read") == nil
    end
  end

  describe "engine_policy/1" do
    test "internal has full access" do
      policy = ToolPolicy.engine_policy(:internal)

      assert policy.allow == :all
      assert policy.deny == []
    end

    test "codex is restricted" do
      policy = ToolPolicy.engine_policy(:codex)

      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "write")
    end

    test "claude is restricted" do
      policy = ToolPolicy.engine_policy(:claude)

      refute ToolPolicy.allowed?(policy, "bash")
    end

    test "kimi is restricted" do
      policy = ToolPolicy.engine_policy(:kimi)

      refute ToolPolicy.allowed?(policy, "bash")
    end
  end

  describe "subagent_policy/2" do
    test "inherits engine restrictions" do
      policy = ToolPolicy.subagent_policy(:codex, [])

      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "agent")
    end

    test "applies additional restrictions from opts" do
      policy = ToolPolicy.subagent_policy(:internal, deny: ["webfetch"])

      assert ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "webfetch")
    end

    test "enables NO_REPLY when specified" do
      policy = ToolPolicy.subagent_policy(:internal, no_reply: true)

      assert ToolPolicy.no_reply?(policy)
    end
  end

  describe "apply_policy/2" do
    test "filters tools based on policy" do
      tools = [
        %{name: "read"},
        %{name: "write"},
        %{name: "bash"}
      ]

      policy = ToolPolicy.from_profile(:read_only)
      allowed = ToolPolicy.apply_policy(policy, tools)

      assert length(allowed) == 1
      assert hd(allowed).name == "read"
    end
  end

  describe "partition_tools/2" do
    test "returns allowed and denied tools" do
      tools = [
        %{name: "read"},
        %{name: "write"},
        %{name: "bash"}
      ]

      policy = ToolPolicy.from_profile(:safe_mode)
      {allowed, denied} = ToolPolicy.partition_tools(policy, tools)

      assert length(allowed) == 1
      assert hd(allowed).name == "read"
      assert length(denied) == 2
    end
  end

  describe "apply_policy_to_map/2" do
    test "filters tools map based on policy" do
      tools_map = %{
        "read" => %{name: "read"},
        "write" => %{name: "write"},
        "bash" => %{name: "bash"}
      }

      policy = ToolPolicy.from_profile(:read_only)
      filtered = ToolPolicy.apply_policy_to_map(policy, tools_map)

      assert map_size(filtered) == 1
      assert Map.has_key?(filtered, "read")
    end
  end

  describe "to_map/1 and from_map/1" do
    test "serializes and deserializes policy" do
      original = ToolPolicy.from_profile(:safe_mode)
      serialized = ToolPolicy.to_map(original)
      deserialized = ToolPolicy.from_map(serialized)

      assert deserialized.allow == original.allow
      assert deserialized.deny == original.deny
      assert deserialized.require_approval == original.require_approval
      assert deserialized.no_reply == original.no_reply
    end

    test "handles :all in allow list" do
      policy = %{allow: :all, deny: [], require_approval: [], no_reply: false}
      serialized = ToolPolicy.to_map(policy)

      assert serialized["allow"] == "all"

      deserialized = ToolPolicy.from_map(serialized)
      assert deserialized.allow == :all
    end
  end

  describe "NO_REPLY support" do
    test "mark_no_reply marks message" do
      message = %{content: "test"}
      marked = ToolPolicy.mark_no_reply(message, reason: "background_task")

      assert marked.no_reply == true
      assert marked.no_reply_reason == "background_task"
    end

    test "message_no_reply? checks flag" do
      message = %{no_reply: true}
      assert ToolPolicy.message_no_reply?(message)

      message = %{"no_reply" => true}
      assert ToolPolicy.message_no_reply?(message)

      message = %{}
      refute ToolPolicy.message_no_reply?(message)
    end

    test "filter_no_reply separates messages" do
      messages = [
        %{id: 1, no_reply: false},
        %{id: 2, no_reply: true},
        %{id: 3}
      ]

      {normal, no_reply} = ToolPolicy.filter_no_reply(messages)

      assert length(normal) == 2
      assert length(no_reply) == 1
      assert hd(no_reply).id == 2
    end
  end
end
