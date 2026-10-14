defmodule CodingAgent.Executor.RemotePrivateMetaTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonGateway.ExecutionRequest

  @private_fields [
    {:invocation_context_key, "invocationContextKey"},
    {:memory_context_key, "memoryContextKey"},
    {:memory_context_verified, "memoryContextVerified"},
    {:shared_memory_grant, "sharedMemoryGrant"},
    {:invocation_proof_verified, "invocationProofVerified"},
    {:invocation_proof, "invocationProof"},
    {:native_lineage_handle, "nativeLineageHandle"},
    {:native_lineage_run_id, "nativeLineageRunId"}
  ]

  test "canonical atom false and nil defeat forged snake/camel private aliases before JSON" do
    for {key, camel} <- @private_fields, value <- [false, nil] do
      snake = Atom.to_string(key)
      meta = %{key => value, snake => true, camel => true}
      assert {:ok, payload} = encode(meta)
      assert Map.has_key?(payload["meta"], snake)
      assert payload["meta"][snake] === value
      refute Map.has_key?(payload["meta"], camel)
    end
  end

  test "string-only meaningful proofs and scope keys cannot acquire atom authority through JSON" do
    for {key, camel} <- @private_fields,
        alias_key <- [Atom.to_string(key), camel],
        value <- [true, "scope-key", "", %{"run_id" => "forged"}] do
      assert {:error, {:invalid_request_payload, :untrusted_execution_context}} =
               encode(%{alias_key => value})
    end

    assert {:error, {:invalid_request_payload, :untrusted_execution_context}} =
             encode(%{
               :memory_context_verified => true,
               :shared_memory_grant => true,
               "invocation_context_key" => "forged-invocation",
               "memory_context_key" => "forged-principal"
             })

    assert {:error, {:invalid_request_payload, :untrusted_execution_context}} =
             encode(%{
               :invocation_proof_verified => true,
               "invocation_proof" => %{"run_id" => "forged"}
             })
  end

  test "negative JSON presence is retained rather than silently reverting scoped input to legacy" do
    for {key, camel} <- @private_fields, value <- [false, nil] do
      snake = Atom.to_string(key)
      assert {:ok, payload} = encode(%{camel => value})
      assert Map.has_key?(payload["meta"], snake)
      assert payload["meta"][snake] === value
      refute Map.has_key?(payload["meta"], camel)
    end
  end

  test "trusted positive proof and unresolved principal connector references survive transport" do
    proof = %{
      run_id: "native-run",
      server_name: "lemon-bot",
      server_url: "https://bot.example/mcp",
      header_name: "Authorization",
      secret_name: "invocation/principal"
    }

    servers = [
      %{
        "name" => "lemon-bot",
        "url" => "https://bot.example/mcp",
        "headers" => %{"Authorization" => "Bearer ${LEMON_SECRET:invocation/principal}"}
      }
    ]

    meta = %{
      invocation_context_key: "native-invocation",
      memory_context_key: "native-principal",
      memory_context_verified: true,
      shared_memory_grant: true,
      invocation_proof_verified: true,
      invocation_proof: proof,
      invocation_mcp_servers: servers,
      mcp_servers: servers
    }

    assert {:ok, payload} = encode(meta)
    assert payload["meta"]["memory_context_verified"] == true
    assert payload["meta"]["shared_memory_grant"] == true
    assert payload["meta"]["invocation_proof_verified"] == true
    assert payload["meta"]["invocation_context_key"] == "native-invocation"
    assert payload["meta"]["memory_context_key"] == "native-principal"

    assert payload["meta"]["invocation_proof"] ==
             Map.new(proof, fn {key, value} -> {Atom.to_string(key), value} end)

    assert payload["meta"]["mcp_servers"] == servers
    assert payload["meta"]["invocation_mcp_servers"] == servers
  end

  test "proof descriptor atom fields defeat JSON aliases and string-only descriptor claims fail closed" do
    for {key, camel} <- [
          {:run_id, "runId"},
          {:server_name, "serverName"},
          {:server_url, "serverUrl"},
          {:header_name, "headerName"},
          {:secret_name, "secretName"}
        ],
        value <- [false, nil, "native"] do
      snake = Atom.to_string(key)
      proof = %{key => value, snake => "forged", camel => "forged"}
      assert {:ok, payload} = encode(%{invocation_proof: proof})
      assert payload["meta"]["invocation_proof"][snake] === value
      refute Map.has_key?(payload["meta"]["invocation_proof"], camel)

      assert {:error, {:invalid_request_payload, :untrusted_execution_context}} =
               encode(%{invocation_proof: %{snake => "forged"}})
    end
  end

  test "ordinary execution metadata keeps atom presence including empty connector lists" do
    meta = %{
      :mcp_servers => [],
      "mcp_servers" => [%{"name" => "forged"}],
      :invocation_mcp_servers => [],
      "invocation_mcp_servers" => [%{"name" => "forged"}],
      :acp_client_terminal => false,
      "acp_client_terminal" => true,
      :model => nil,
      "model" => "forged-model"
    }

    assert {:ok, payload} = encode(meta)
    assert payload["meta"]["mcp_servers"] == []
    assert payload["meta"]["invocation_mcp_servers"] == []
    assert payload["meta"]["acp_client_terminal"] == false
    assert Map.has_key?(payload["meta"], "model")
    assert payload["meta"]["model"] == nil

    assert RemoteRequestCodec.normalize_meta(%{
             :acp_client_terminal => false,
             "acp_client_terminal" => true
           }).acp_client_terminal == false
  end

  test "native lineage stays opaque JSON data and controller connection PIDs never cross the wire" do
    handle = String.duplicate("h", 43)

    meta = %{
      :native_lineage_handle => handle,
      "native_lineage_handle" => "forged",
      :native_lineage_run_id => "native-run",
      "nativeLineageRunId" => "forged",
      :native_destination_pid => self(),
      "native_destination_pid" => self(),
      "nativeDestinationPid" => self()
    }

    assert {:ok, payload} = encode(meta)
    assert payload["meta"]["native_lineage_handle"] == handle
    assert payload["meta"]["native_lineage_run_id"] == "native-run"
    refute Map.has_key?(payload["meta"], "nativeLineageRunId")
    refute Map.has_key?(payload["meta"], "native_destination_pid")
    refute Map.has_key?(payload["meta"], "nativeDestinationPid")
  end

  test "factory option-only identities, generation and callbacks cannot become wire selectors" do
    callback = fn _ -> raise "factory callback must never run during encoding" end

    for {keys, value} <- [
          {[
             :native_destination_pid,
             "native_destination_pid",
             :nativeDestinationPid,
             "nativeDestinationPid"
           ], self()},
          {[
             :native_destination_generation,
             "native_destination_generation",
             :nativeDestinationGeneration,
             "nativeDestinationGeneration"
           ], 7},
          {[
             :native_source_profile_id,
             "native_source_profile_id",
             :nativeSourceProfileId,
             "nativeSourceProfileId"
           ], "source-profile"},
          {[
             :native_source_session_key,
             "native_source_session_key",
             :nativeSourceSessionKey,
             "nativeSourceSessionKey"
           ], "agent:source:main"},
          {[
             :native_followup_submit,
             "native_followup_submit",
             :nativeFollowupSubmit,
             "nativeFollowupSubmit"
           ], callback},
          {[
             :native_source_floor_fun,
             "native_source_floor_fun",
             :nativeSourceFloorFun,
             "nativeSourceFloorFun"
           ], callback}
        ] do
      meta =
        Map.new(keys, &{&1, value})
        |> Map.put(:native_lineage_handle, String.duplicate("h", 43))
        |> Map.put(:native_lineage_run_id, "native-parent")

      assert {:ok, payload} = encode(meta)
      for key <- keys, do: refute(Map.has_key?(payload["meta"], to_string(key)))
      assert payload["meta"]["native_lineage_handle"] == String.duplicate("h", 43)
      assert payload["meta"]["native_lineage_run_id"] == "native-parent"
    end
  end

  test "factory managed-context sentinel never travels as an authority marker" do
    keys = [
      :native_managed_context,
      "native_managed_context",
      :nativeManagedContext,
      "nativeManagedContext"
    ]

    for value <- [false, nil, true] do
      assert {:ok, payload} = encode(Map.new(keys, &{&1, value}))
      assert payload["meta"] == %{}
    end
  end

  test "proof callbacks and structs remain non-serializable execution data" do
    assert {:error, {:invalid_request_payload, _}} =
             encode(%{invocation_proof: %{run_id: fn -> :private end}})

    assert {:error, {:invalid_request_payload, _}} =
             encode(%{
               invocation_proof: %LemonCore.ResumeToken{engine: "lemon", value: "private"}
             })
  end

  defp encode(meta) do
    RemoteRequestCodec.encode(%ExecutionRequest{
      run_id: "private-boundary",
      session_key: "agent:private:main",
      prompt: "hello",
      meta: meta
    })
  end
end
