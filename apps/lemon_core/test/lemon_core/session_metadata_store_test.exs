defmodule LemonCore.SessionMetadataStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.SessionMetadataStore

  setup do
    clear_metadata()
    on_exit(&clear_metadata/0)
    :ok
  end

  test "patches title, pin, and archive state without storing conversation content" do
    session_key = unique_session_key()

    assert {:ok, metadata} =
             SessionMetadataStore.patch(session_key, %{
               "title" => "  Release checklist  ",
               "pinned" => true,
               "archived" => false
             })

    assert metadata.session_key == session_key
    assert metadata.title == "Release checklist"
    assert metadata.pinned == true
    assert metadata.archived == false
    assert is_integer(metadata.created_at_ms)
    assert is_integer(metadata.updated_at_ms)

    assert [{^session_key, listed}] = SessionMetadataStore.list()
    assert listed == SessionMetadataStore.get(session_key)
    refute Map.has_key?(listed, :messages)
    refute Map.has_key?(listed, :runs)
  end

  test "supports clearing a title and applying false booleans" do
    session_key = unique_session_key()

    assert {:ok, _} =
             SessionMetadataStore.patch(session_key, %{
               title: "Pinned",
               pinned: true,
               archived: true
             })

    assert {:ok, metadata} =
             SessionMetadataStore.patch(session_key, %{title: "", pinned: false, archived: false})

    assert metadata.title == nil
    assert metadata.pinned == false
    assert metadata.archived == false
  end

  test "rejects empty, oversized, and mistyped patches" do
    session_key = unique_session_key()

    assert {:error, :empty_patch} = SessionMetadataStore.patch(session_key, %{})

    assert {:error, {:invalid_title, :too_long}} =
             SessionMetadataStore.patch(session_key, %{title: String.duplicate("x", 161)})

    assert {:error, {:invalid_boolean, :pinned}} =
             SessionMetadataStore.patch(session_key, %{pinned: "yes"})

    assert SessionMetadataStore.get(session_key).title == nil
  end

  test "stores ACP metadata on the canonical session key, drops legacy fields, and preserves it across patches" do
    session_key = unique_session_key()

    assert :ok =
             SessionMetadataStore.put_acp(session_key, %{
               session_id: "acp_123",
               session_key: session_key,
               cwd: "/tmp/project",
               last_run_id: "run_1",
               cancelled_run_id: "run_0",
               mode: "plan",
               native_resume: "legacy-token"
             })

    assert {:ok, acp} = SessionMetadataStore.fetch_acp(session_key)
    assert acp.session_id == "acp_123"
    assert acp.last_run_id == "run_1"
    refute Map.has_key?(acp, :mode)
    refute Map.has_key?(acp, :native_resume)

    assert {:ok, ^acp} = SessionMetadataStore.fetch_acp_by_id("acp_123")
    assert [{"acp_123", ^acp}] = SessionMetadataStore.list_acp()

    assert {:ok, patched} =
             SessionMetadataStore.patch(session_key, %{title: "ACP work", pinned: true})

    assert patched.title == "ACP work"
    assert patched.pinned == true
    assert {:ok, ^acp} = SessionMetadataStore.fetch_acp(session_key)

    assert :ok = SessionMetadataStore.clear_acp_run_state(session_key)
    assert {:ok, cleared} = SessionMetadataStore.fetch_acp(session_key)
    assert cleared.last_run_id == nil
    refute Map.has_key?(cleared, :cancelled_run_id)
    assert cleared.cwd == "/tmp/project"
  end

  defp clear_metadata do
    LemonCore.Store.list(:session_metadata_v1)
    |> Enum.each(fn {key, _value} -> LemonCore.Store.delete(:session_metadata_v1, key) end)
  end

  defp unique_session_key do
    "agent:metadata_#{System.unique_integer([:positive, :monotonic])}:main"
  end
end
