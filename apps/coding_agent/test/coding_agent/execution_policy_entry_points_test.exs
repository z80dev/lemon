defmodule CodingAgent.ExecutionPolicyEntryPointsTest do
  @moduledoc """
  Every native execution entry point applies the same validated tool-policy
  semantics (#72): direct sessions, the native executor, task delegation, and
  both sides of a named-node hop reject malformed supplied policy before any
  session starts, and resolve a valid policy to identical authority.
  """

  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.Worker
  alias CodingAgent.Executor
  alias CodingAgent.Executor.RemoteRequestCodec
  alias CodingAgent.Session
  alias CodingAgent.Tools.Task.Params
  alias LemonCore.{ExecutionContext, ToolPolicy}
  alias LemonCore.ExecutionCommand

  @tools ~w(read grep write edit bash task agent webfetch zz_unclassified_tool)

  @malformed [
    %{"allow" => 123},
    %{allow: %{"read" => true}},
    %{"allow" => "read"},
    %{"profile" => "root"},
    %{profile: :superuser},
    %{"deny" => "bash"},
    %{"blocked_tools" => [""]},
    %{"require_approval" => [1]},
    %{"approvals" => %{"bash" => "maybe"}},
    %{"approval_mode" => "sometimes"},
    %{"files" => true},
    %{"allow" => ["read"], allow: ["read", "bash"]},
    "root",
    :superuser,
    false,
    ["read"]
  ]

  @valid [
    %{"allow" => ["read", "grep", "bash"], "deny" => ["bash"]},
    %{"profile" => "read_only"},
    %{profile: :safe_mode, require_approval: [:write]},
    %{"approval_mode" => "ask", "approvals" => %{"read" => "never"}},
    %{allow: [:read, "edit"], approvals: %{"edit" => :always}},
    "leaf_worker",
    :no_external
  ]

  @tag :tmp_dir
  test "malformed supplied policy is rejected at every entry point before execution", %{
    tmp_dir: tmp_dir
  } do
    for policy <- @malformed do
      label = inspect(policy)
      # Every boundary reports the canonical parser's reason, so none of them
      # rejects for an unrelated reason or normalizes the input first.
      assert {:error, reason} = ToolPolicy.parse(policy), label

      assert {:error, ^reason} = Session.start_link(cwd: tmp_dir, tool_policy: policy), label

      assert {:error, ^reason} =
               Executor.start_run(executor_request(tmp_dir, policy, nil), %{}, self()),
             label

      assert {:error, ^reason} =
               Executor.start_run(
                 executor_request(tmp_dir, policy, root_context(tmp_dir, "executor")),
                 %{},
                 self()
               ),
             label

      task_error = "Task execution authority is invalid: #{inspect(reason)}"

      assert {:error, ^task_error} =
               Params.restrict_to_parent(%{tool_policy: policy}, tmp_dir,
                 execution_context: root_context(tmp_dir, "task-parent")
               ),
             label

      assert {:error, ^reason} = remote_payload(tmp_dir, policy), label

      {:ok, payload} = remote_payload(tmp_dir, nil)

      assert {:error, ^reason} =
               payload
               |> Map.put("toolPolicy", policy)
               |> Worker.execution_request(worker(tmp_dir), "invoke"),
             label

      assert {:error, ^reason} =
               payload
               |> put_in(["executionContext", "toolPolicy"], policy)
               |> Worker.execution_request(worker(tmp_dir), "invoke"),
             label
    end

    refute_receive {:engine_event, _, _}, 50
  end

  @tag :tmp_dir
  test "a valid policy resolves to identical authority at every entry point", %{
    tmp_dir: tmp_dir
  } do
    for policy <- @valid do
      expected = ToolPolicy.parse!(policy)

      assert {:ok, opts} = Session.validate_execution_options(cwd: tmp_dir, tool_policy: policy)
      assert_same_authority(opts[:tool_policy], expected, {:direct, policy})
      assert_same_authority(opts[:execution_context].tool_policy, expected, {:direct, policy})

      assert {:ok, task} =
               Params.restrict_to_parent(%{tool_policy: policy}, tmp_dir,
                 execution_context: root_context(tmp_dir, "task-parent")
               )

      assert_same_authority(task.tool_policy, expected, {:task, policy})
      assert task.execution_context.parent_run_id == "task-parent"

      assert {:ok, payload} = remote_payload(tmp_dir, policy)

      assert {:ok, request, _opts} =
               Worker.execution_request(payload, worker(tmp_dir), "invoke")

      assert_same_authority(request.tool_policy, expected, {:named_node, policy})

      assert_same_authority(
        request.execution_context.tool_policy,
        expected,
        {:named_node_context, policy}
      )
    end
  end

  @tag :tmp_dir
  test "delegated and remote policy cannot exceed the parent authority", %{tmp_dir: tmp_dir} do
    {:ok, parent} =
      ExecutionContext.new(
        run_id: "bounded-parent",
        cwd: tmp_dir,
        tool_policy: %{"allow" => ["read", "grep"], "require_approval" => ["grep"]}
      )

    widening = %{
      "profile" => "full_access",
      "allow" => "all",
      "approvals" => %{"grep" => "never"}
    }

    assert {:ok, task} =
             Params.restrict_to_parent(%{tool_policy: widening}, tmp_dir,
               execution_context: parent
             )

    assert {:ok, payload} =
             RemoteRequestCodec.encode(%ExecutionCommand{
               run_id: "bounded-parent",
               session_key: "agent:bounded:main",
               prompt: "work",
               cwd: tmp_dir,
               tool_policy: widening,
               execution_context: parent
             })

    assert {:ok, remote, _opts} = Worker.execution_request(payload, worker(tmp_dir), "invoke")

    for policy <- [task.tool_policy, remote.tool_policy, remote.execution_context.tool_policy] do
      assert ToolPolicy.allowed?(policy, "read")
      refute ToolPolicy.allowed?(policy, "bash")
      refute ToolPolicy.allowed?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "grep")
      assert ToolPolicy.subset?(policy, parent.tool_policy)
    end

    assert ExecutionContext.subset?(task.execution_context, parent)
  end

  defp assert_same_authority(actual, expected, label) do
    for tool <- @tools do
      assert ToolPolicy.allowed?(actual, tool) == ToolPolicy.allowed?(expected, tool),
             "#{inspect(label)} allow #{tool}"

      assert ToolPolicy.requires_approval?(actual, tool) ==
               ToolPolicy.requires_approval?(expected, tool),
             "#{inspect(label)} approval #{tool}"
    end
  end

  defp root_context(cwd, run_id) do
    {:ok, context} = ExecutionContext.new(run_id: run_id, cwd: cwd)
    context
  end

  defp executor_request(cwd, policy, context) do
    %ExecutionCommand{
      run_id: (context && context.run_id) || "entry-#{System.unique_integer([:positive])}",
      session_key: "agent:entry-points:#{System.unique_integer([:positive])}",
      prompt: "must not start",
      cwd: cwd,
      tool_policy: policy,
      execution_context: context,
      meta: %{stream_fn: fn _, _, _ -> flunk("invalid policy must not reach a provider") end}
    }
  end

  defp remote_payload(cwd, policy) do
    context = root_context(cwd, "remote-#{System.unique_integer([:positive])}")

    RemoteRequestCodec.encode(%ExecutionCommand{
      run_id: context.run_id,
      session_key: "agent:entry-points:main",
      prompt: "work",
      cwd: cwd,
      tool_policy: policy,
      execution_context: context
    })
  end

  defp worker(cwd) do
    %Worker{name: "entry-points", default_cwd: cwd, services: %{execution_capabilities: :all}}
  end
end
