{:ok, _} = Application.ensure_all_started(:coding_agent)

alias AgentCore.Types.AgentToolResult
alias Ai.Types.TextContent
alias CodingAgent.ToolRegistry
alias AgentCore.Types.AgentTool

now = DateTime.utc_now()

make_tool = fn name ->
  %AgentTool{
    name: name,
    description: "#{name} policy proof tool",
    parameters: %{"type" => "object"},
    label: name,
    execute: fn _tool_call_id, _params, _signal, _on_update ->
      %AgentToolResult{content: [%TextContent{text: "executed #{name}"}], trust: :untrusted}
    end
  }
end

run_tool = fn tool_name, capabilities, policy ->
  parent = self()

  approval_context = %{
    session_key: "wasm-policy-proof",
    approval_request_fun: fn request ->
      send(parent, {:approval_requested, request})
      {:ok, :denied}
    end
  }

  wasm_inventory = [
    {tool_name, make_tool.(tool_name),
     {:wasm,
      %{
        name: tool_name,
        path: "/private/wasm/#{tool_name}.wasm",
        path_hash: :crypto.hash(:sha256, tool_name) |> Base.encode16(case: :lower),
        capabilities: capabilities
      }}}
  ]

  [tool] =
    ToolRegistry.get_tools(File.cwd!(),
      include_extensions: false,
      wasm_tools: wasm_inventory,
      tool_policy: policy,
      approval_context: approval_context,
      enabled_only: [tool_name]
    )

  result = tool.execute.("raw-policy-call-#{tool_name}", %{"secret" => "do-not-leak"}, nil, nil)

  approval_requested? =
    receive do
      {:approval_requested, _request} -> true
    after
      25 -> false
    end

  text =
    result.content
    |> List.wrap()
    |> Enum.map(fn
      %TextContent{text: text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")

  %{approval_requested?: approval_requested?, result_text: text}
end

base_policy = %{allow: :all, deny: [], require_approval: [], approvals: %{}}
never_policy = %{base_policy | approvals: %{"http_never_wasm" => :never}}

scenarios = [
  {"wasm_policy_http_requires_approval", "http_wasm", %{http: true}, base_policy, true, false},
  {"wasm_policy_tool_invoke_requires_approval", "invoke_wasm", %{tool_invoke: true}, base_policy,
   true, false},
  {"wasm_policy_exec_requires_approval", "exec_wasm", %{exec: true}, base_policy, true, false},
  {"wasm_policy_safe_capabilities_execute_without_approval", "safe_wasm",
   %{http: false, tool_invoke: false, exec: false}, base_policy, false, true},
  {"wasm_policy_explicit_never_overrides_default_approval", "http_never_wasm", %{http: true},
   never_policy, false, true}
]

checks =
  Enum.map(scenarios, fn {check_name, tool_name, capabilities, policy, expects_approval?,
                          expects_execution?} ->
    result = run_tool.(tool_name, capabilities, policy)

    approved_result? =
      result.approval_requested? == expects_approval? and
        String.contains?(result.result_text, "denied") != expects_execution? and
        String.contains?(result.result_text, "executed") == expects_execution?

    %{
      name: check_name,
      status: if(approved_result?, do: "completed", else: "failed")
    }
  end)

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "wasm_policy_smoke",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "policy_boundary" => %{
    "http_requires_approval_by_default" => true,
    "tool_invoke_requires_approval_by_default" => true,
    "exec_requires_approval_by_default" => true,
    "safe_capabilities_execute_without_approval" => true,
    "explicit_never_can_override_default" => true
  },
  "redaction" => %{
    "contains_raw_paths" => false,
    "contains_raw_params" => false,
    "contains_raw_tool_call_ids" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/wasm-policy-latest.json", json <> "\n")

archive =
  ".lemon/proofs/wasm-policy-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

if failed_count == 0 do
  IO.puts("wasm policy smoke proof passed: #{completed_count} completed")
else
  IO.puts("wasm policy smoke proof failed: #{failed_count} failed")
  System.halt(1)
end
