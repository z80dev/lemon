defmodule LemonMemory.ContextScopeTest do
  use ExUnit.Case, async: true
  alias LemonMemory.{ContextScope, Document}

  test "only admitted atom keys and proof establish native ownership" do
    trusted = %{memory_context_key: "actor-a", invocation_context_key: "epoch-1",
                memory_context_verified: true}
    assert {:ok, {:private, "actor-a"}} = ContextScope.scope(trusted)
    assert {:ok, {:private, "actor-a"}} = ContextScope.scope(%{trusted | invocation_context_key: "epoch-2"})
    assert {:ok, :legacy} = ContextScope.scope(%{memory_context_key: nil, invocation_context_key: nil,
                                               memory_context_verified: false})
    for unproven <- [Map.delete(trusted, :memory_context_verified),
                     %{trusted | invocation_context_key: nil},
                     %{trusted | memory_context_key: "bad/key"},
                     %{"memory_context_key" => "actor-a", "invocation_context_key" => "epoch-1",
                       "memory_context_verified" => true},
                     %{"memoryScope" => "private", "memoryContextKey" => "actor-a"}] do
      assert {:error, :unproven_context} = ContextScope.scope(unproven)
    end
    refute ContextScope.shared_grant?(Map.put(trusted, "shared_memory_grant", true))
    assert ContextScope.shared_grant?(Map.put(trusted, :shared_memory_grant, true))
    refute ContextScope.shared_grant?(%{shared_memory_grant: true})
  end

  test "management selections are explicit and reject malformed or mixed ownership" do
    assert {:ok, :operator} = ContextScope.selection(%{})
    assert {:ok, {:private, "actor-a"}} = ContextScope.selection(%{"memoryScope" => "private", "memoryContextKey" => "actor-a"})
    assert {:ok, :shared} = ContextScope.selection(%{"memoryScope" => "shared"})
    for params <- [%{"memoryScope" => "private"}, %{"memoryContextKey" => "actor-a"},
                   %{"memoryScope" => "shared", "memoryContextKey" => "actor-a"},
                   %{"memoryScope" => "private", "memoryContextKey" => String.duplicate("a", 129)},
                   %{"memoryScope" => "private", "memoryContextKey" => "é"},
                   %{"memoryScope" => "public"}] do
      assert {:error, :invalid_memory_scope} = ContextScope.selection(params)
    end
    refute ContextScope.matches?(%{}, :shared)
    refute ContextScope.matches?(%{"memory_scope" => "shared"}, :shared)
    assert ContextScope.matches?(ContextScope.metadata(:shared), :shared)
    refute ContextScope.matches?(ContextScope.metadata({:private, "actor-a"}), :legacy)
    refute ContextScope.matches?(%{"invocation_context_key" => "epoch"}, :legacy)
  end

  test "camel atom claims cannot silently become legacy or grant native proof" do
    claims = %{memoryScope: "private", memoryContextKey: "actor-a",
               invocationContextKey: "epoch-1", memoryContextVerified: true}
    assert {:error, :unproven_context} = ContextScope.scope(claims)
    assert ContextScope.run_metadata(claims) == %{"memory_scope" => "unproven"}
  end

  test "indexing strips string/provider claims, stamps native proof, and never shares runs" do
    # Mixed atom/string maps use explicit tuples to avoid keyword ordering.
    trusted = Map.merge(%{"memory_scope" => "shared", "memory_shared_verified" => true,
                          "memory_context_key" => "actor-b"},
                        %{memory_context_key: "actor-a", invocation_context_key: "epoch-1",
                          memory_context_verified: true, shared_memory_grant: true})
    doc = run(trusted)
    assert ContextScope.matches?(doc.meta, {:private, "actor-a"})
    refute ContextScope.matches?(doc.meta, :shared)
    refute Map.has_key?(doc.meta, :memory_context_verified)
    refute Map.has_key?(doc.meta, "invocation_context_key")
    refute Map.has_key?(doc.meta, "shared_memory_grant")
    claimed = run(%{"memory_scope" => "shared", "memory_shared_verified" => true,
                    "memory_context_key" => "actor-a", "memory_context_verified" => true,
                    "invocation_context_key" => "epoch-1"})
    assert claimed.meta["memory_scope"] == "unproven"
    refute ContextScope.matches?(claimed.meta, {:private, "actor-a"})
    refute ContextScope.matches?(claimed.meta, :shared)
    assert run(%{}).meta["memory_scope"] == "legacy"
    nested = Document.from_run("run", %{}, %{session_key: "agent:coding:main", agent_id: "coding",
      completed: %{meta: %{memory_context_key: "actor-a", invocation_context_key: "epoch-1",
                          memory_context_verified: true}}})
    assert nested.meta["memory_scope"] == "legacy"
  end

  defp run(meta), do: Document.from_run("run", %{}, %{
    session_key: "agent:coding:main", agent_id: "coding", meta: meta
  })
end
