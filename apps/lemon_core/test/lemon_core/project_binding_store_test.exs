defmodule LemonCore.ProjectBindingStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProjectBindingStore

  test "round-trips project overrides through the typed wrapper" do
    scope = "scope_#{System.unique_integer([:positive])}"

    assert :ok = ProjectBindingStore.put_override(scope, "configured-project")
    assert ProjectBindingStore.get_override(scope) == "configured-project"

    assert Enum.any?(ProjectBindingStore.list_overrides(), fn {stored_scope, project_id} ->
             stored_scope == scope and project_id == "configured-project"
           end)

    assert :ok = ProjectBindingStore.delete_override(scope)
    assert ProjectBindingStore.get_override(scope) == nil
  end

  test "a stored legacy dynamic project never resolves" do
    project_id = "legacy_#{System.unique_integer([:positive])}"
    :ok = LemonCore.Store.put(:projects_dynamic, project_id, %{root: "/tmp"})
    on_exit(fn -> LemonCore.Store.delete(:projects_dynamic, project_id) end)

    assert LemonCore.BindingResolver.lookup_project(project_id, fn -> %{} end) == nil

    assert LemonCore.BindingResolver.lookup_project(project_id, fn ->
             %{project_id => %{root: "/srv/configured"}}
           end) == %{root: "/srv/configured"}
  end
end
