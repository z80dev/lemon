defmodule LemonCore.ProjectBindingStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProjectBindingStore

  test "round-trips project overrides and dynamic bindings through the typed wrapper" do
    project_id = "project_#{System.unique_integer([:positive])}"
    override = %{cwd: "/tmp/project", default_engine: "codex"}
    dynamic = %{path: "/tmp/project", source: :test}

    assert :ok = ProjectBindingStore.put_override(project_id, override)
    assert ProjectBindingStore.get_override(project_id) == override

    assert Enum.any?(ProjectBindingStore.list_overrides(), fn {stored_project_id, stored_override} ->
             stored_project_id == project_id and stored_override == override
           end)

    assert :ok = ProjectBindingStore.put_dynamic(project_id, dynamic)
    assert ProjectBindingStore.get_dynamic(project_id) == dynamic

    assert Enum.any?(ProjectBindingStore.list_dynamic(), fn {stored_project_id, stored_dynamic} ->
             stored_project_id == project_id and stored_dynamic == dynamic
           end)

    assert :ok = ProjectBindingStore.delete_override(project_id)
    assert :ok = ProjectBindingStore.delete_dynamic(project_id)
    assert ProjectBindingStore.get_override(project_id) == nil
    assert ProjectBindingStore.get_dynamic(project_id) == nil
  end
end
