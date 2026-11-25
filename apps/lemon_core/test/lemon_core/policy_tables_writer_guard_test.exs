defmodule LemonCore.PolicyTablesWriterGuardTest do
  @moduledoc """
  Every policy table that production code reads must have a production writer.

  Policy and approval-memory tables are registered here with their typed
  readers and writers. The guard scans `apps/*/lib` (the owning store module
  excluded) and fails when a registered table is read but never written, when
  a typed accessor is not registered, or when any code names a `*polic*` Store
  table this registry does not know (a new or resurrected unwritten plane).
  """
  use ExUnit.Case, async: true

  @tables %{
    session_policies: %{
      module: "PolicyStore",
      readers: [:fetch_session],
      writers: [:put_session, :update_session],
      deleters: [:delete_session]
    },
    exec_approvals_policy: %{
      module: "ExecApprovalStore",
      readers: [:get_global_policy, :fetch_global_policies],
      writers: [:put_global_policy],
      deleters: []
    },
    exec_approvals_policy_agent: %{
      module: "ExecApprovalStore",
      readers: [:get_agent_policy],
      writers: [:put_agent_policy],
      deleters: []
    },
    exec_approvals_policy_session: %{
      module: "ExecApprovalStore",
      readers: [:get_session_policy],
      writers: [:put_session_policy],
      deleters: []
    },
    model_policies: %{
      module: "ModelPolicyStore",
      readers: [:get, :list],
      writers: [:put],
      deleters: [:delete]
    }
  }

  @owners %{
    "PolicyStore" => {LemonCore.PolicyStore, "apps/lemon_core/lib/lemon_core/policy_store.ex"},
    "ExecApprovalStore" =>
      {LemonCore.ExecApprovalStore, "apps/lemon_core/lib/lemon_core/exec_approval_store.ex"},
    "ModelPolicyStore" =>
      {LemonChannels.ModelPolicyStore,
       "apps/lemon_channels/lib/lemon_channels/model_policy_store.ex"}
  }

  @root Path.expand("../../../..", __DIR__)

  setup_all do
    sources =
      @root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Map.new(fn file -> {Path.relative_to(file, @root), File.read!(file)} end)

    {:ok, sources: sources}
  end

  test "every policy table read in production has a production writer", %{sources: sources} do
    unwritten =
      for {table, spec} <- @tables,
          {_module, owner_path} = Map.fetch!(@owners, spec.module),
          production = Map.delete(sources, owner_path),
          called?(production, spec.module, spec.readers),
          not called?(production, spec.module, spec.writers),
          do: table

    assert unwritten == [],
           "policy tables read without any production writer: #{inspect(unwritten)}"
  end

  test "every typed policy accessor is registered with its table" do
    for {name, {module, _path}} <- @owners do
      registered =
        for {_table, %{module: ^name} = spec} <- @tables,
            fun <- spec.readers ++ spec.writers ++ spec.deleters,
            do: fun

      policy_accessors =
        for {fun, _arity} <- module.__info__(:functions),
            name != "ExecApprovalStore" or String.contains?(Atom.to_string(fun), "_polic"),
            uniq: true,
            do: fun

      assert Enum.sort(policy_accessors -- registered) == [],
             "#{name} exposes unregistered policy accessors: " <>
               inspect(policy_accessors -- registered)
    end
  end

  test "no code names a policy Store table outside the registry", %{sources: sources} do
    known = Map.keys(@tables)

    unknown =
      for {path, source} <- sources,
          [_, table] <-
            Regex.scan(~r/(?:@\w+\s+|Store\.\w+\(\s*):(\w*polic(?:y|ies)\w*)\b/, source),
          String.to_atom(table) not in known,
          uniq: true,
          do: {path, table}

    assert unknown == [], "unregistered policy tables: #{inspect(unknown)}"
  end

  defp called?(sources, module, funs) do
    pattern = ~r/\b#{module}\.(#{Enum.map_join(funs, "|", &Atom.to_string/1)})\b/

    Enum.any?(sources, fn {_path, source} -> Regex.match?(pattern, source) end)
  end
end
