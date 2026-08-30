defmodule LemonAgent.Security.ToolResultTrustTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  test "marks data results untrusted without claiming they were already wrapped" do
    result = %AgentToolResult{
      content: [%TextContent{text: "file data"}],
      details: %{path: "/tmp/file"}
    }

    assert %AgentToolResult{
             trust: :untrusted,
             details: %{
               path: "/tmp/file",
               trust_boundary: %{
                 "source" => "local_file",
                 "untrusted" => true,
                 "wrapping_applied" => false,
                 "wrapped_fields" => []
               }
             }
           } = ToolResultTrust.untrusted(result, :local_file)
  end

  test "keeps only passing builtin skill semantics trusted" do
    result = %AgentToolResult{content: [%TextContent{text: "instructions"}]}

    entry = %{
      source_kind: :builtin,
      trust_level: :builtin,
      audit_status: :pass
    }

    assert %AgentToolResult{trust: :untrusted} = ToolResultTrust.skill(result, entry)

    assert %AgentToolResult{trust: :trusted} =
             ToolResultTrust.skill(result, entry, true)

    for entry <- [
          %{source_kind: :builtin, trust_level: :builtin, audit_status: :warn},
          %{source_kind: :git, trust_level: :community, audit_status: :pass},
          %{source_kind: :local, trust_level: nil, audit_status: nil}
        ] do
      assert %AgentToolResult{trust: :untrusted} = ToolResultTrust.skill(result, entry, true)
    end
  end
end
