defmodule LemonCore.InvocationProofTest do
  use ExUnit.Case, async: true

  alias LemonCore.InvocationProof

  test "descriptor binds the submitted fixed ID and exact actual server header" do
    {descriptor, servers} = proof("fixed-A")
    assert {:ok, record} = InvocationProof.validate(descriptor, "fixed-A", servers)
    assert record.run_id == "fixed-A"
    assert record.secret_name == "lemon_bot/invocations/fixed-A"

    for changed <- [
          Map.put(descriptor, "runId", "fixed-B"),
          Map.put(descriptor, "serverName", "another-server"),
          Map.put(descriptor, "serverUrl", "https://other.example/mcp"),
          Map.put(descriptor, "headerName", "Authorization"),
          Map.put(descriptor, "secretName", "lemon_bot/invocations/fixed-B"),
          Map.put(descriptor, "verified", true)
        ] do
      assert {:error, :invalid_invocation_proof} =
               InvocationProof.validate(changed, "fixed-A", servers)
    end

    wrong_header = put_in(hd(servers), ["headers", "X-Lemon-Bot-Invocation"], "a-raw-token")
    assert {:error, :invalid_invocation_proof} =
             InvocationProof.validate(descriptor, "fixed-A", [wrong_header])
    assert {:error, :invalid_invocation_proof} =
             InvocationProof.validate(descriptor, "fixed-A", servers ++ servers)
  end

  test "only a verified exact proof value rotates in a comparison projection" do
    first = request("fixed-A")
    second = request("fixed-B")

    assert InvocationProof.comparison_servers(first) == InvocationProof.comparison_servers(second)
    refute first.meta.mcp_servers == second.meta.mcp_servers
    assert first.meta.mcp_servers |> hd() |> Map.get("headers") |> Map.get("X-Lemon-Bot-Invocation") ==
             "${LEMON_SECRET:lemon_bot/invocations/fixed-A}"

    changed = update_in(second.meta.mcp_servers, fn [server] ->
      [put_in(server, ["headers", "X-Another-Authority"], "changed-authority")]
    end)
    refute InvocationProof.comparison_servers(first) == InvocationProof.comparison_servers(changed)

    changed_url = update_in(second.meta.mcp_servers, fn [server] ->
      [Map.put(server, "url", "https://other.example/mcp")]
    end)
    assert InvocationProof.comparison_servers(changed_url) == changed_url.meta.mcp_servers
  end

  test "missing, shadowed, borrowed, and unattested metadata cannot mask authority" do
    original = request("fixed-A")

    altered_metadata = [
      Map.delete(original.meta, :invocation_proof_verified),
      Map.put(original.meta, :invocation_proof_verified, false),
      Map.delete(original.meta, :memory_context_verified),
      Map.put(original.meta, :memory_context_verified, false),
      Map.delete(original.meta, :invocation_context_key),
      Map.delete(original.meta, :memory_context_key),
      original.meta |> Map.put(:invocation_context_key, nil) |> Map.put("invocation_context_key", "forged"),
      original.meta |> Map.put(:invocation_proof_verified, false) |> Map.put("invocation_proof_verified", true),
      original.meta |> Map.delete(:invocation_proof_verified) |> Map.put("invocation_proof_verified", true)
    ]

    for meta <- altered_metadata do
      assert InvocationProof.comparison_servers(%{original | meta: meta}) == original.meta.mcp_servers
    end

    borrowed = %{original | run_id: "fixed-B"}
    assert InvocationProof.comparison_servers(borrowed) == original.meta.mcp_servers
  end

  test "authenticated projection factory binds fresh execution without borrowing another run proof" do
    {descriptor, servers} = proof("fresh-F")
    original = %{run_id: "fresh-F", meta: %{mcp_servers: servers, tool_policy: %{allow: ["read"]}}}
    projection = %{
      "runId" => "fresh-F",
      "invocationContextKey" => "current-principal-policy-epoch",
      "memoryContextKey" => "authorized-private-audience",
      "invocationProof" => descriptor,
      "sharedMemoryGrant" => false
    }

    assert {:ok, admitted} = InvocationProof.attach_execution_context(original, projection)
    assert admitted.run_id == "fresh-F"
    assert admitted.meta.mcp_servers == servers
    assert admitted.meta.tool_policy == %{allow: ["read"]}
    assert admitted.meta.memory_context_verified == true
    assert admitted.meta.invocation_proof.run_id == "fresh-F"
    assert admitted.meta.invocation_proof_verified == true

    for invalid <- [
          Map.put(projection, "runId", "another-F"),
          Map.delete(projection, "runId"),
          Map.delete(projection, "memoryContextKey"),
          Map.delete(projection, "invocationContextKey"),
          Map.put(projection, "memoryContextKey", nil),
          Map.put(projection, "sharedMemoryGrant", "false")
        ] do
      assert {:error, _} = InvocationProof.attach_execution_context(original, invalid)
    end

    {borrowed, _} = proof("previous-root")
    assert {:error, :invalid_invocation_proof} =
             InvocationProof.attach_execution_context(original, Map.put(projection, "invocationProof", borrowed))
  end

  defp request(run_id) do
    {descriptor, servers} = proof(run_id)
    {:ok, record} = InvocationProof.validate(descriptor, run_id, servers)

    %{
      run_id: run_id,
      meta: %{
        mcp_servers: servers,
        invocation_context_key: "principal-policy-connectors-epoch",
        memory_context_key: "principal-private-audience",
        memory_context_verified: true,
        shared_memory_grant: false,
        invocation_proof: record,
        invocation_proof_verified: true
      }
    }
  end

  defp proof(run_id) do
    descriptor = %{
      "runId" => run_id,
      "serverName" => "core",
      "serverUrl" => "https://core.example/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => "lemon_bot/invocations/" <> run_id
    }

    servers = [%{
      "name" => "core",
      "url" => "https://core.example/mcp",
      "headers" => %{
        "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}",
        "X-Another-Authority" => "unchanged-authority"
      }
    }]

    {descriptor, servers}
  end
end
