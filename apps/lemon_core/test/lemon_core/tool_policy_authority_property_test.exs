defmodule LemonCore.ToolPolicyAuthorityPropertyTest do
  @moduledoc """
  Authority invariants for validated tool-policy parsing (#71) and for every
  projection execution consumes (#72): malformed supplied policy never grants a
  tool, and normalization, transport and intersection never widen authority.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.{Config, ToolPolicy}

  @tools ~w(read grep write edit bash eval task agent webfetch zz_unclassified_tool)
  @profiles ~w(full_access orchestrator leaf_worker minimal_core read_only safe_mode subagent_restricted no_external custom)a

  # Field -> values the strict parser must reject in either key form.
  @malformed_fields %{
    allow: [123, true, "read", %{"read" => true}, ["bad tool"], [nil], [1], [""]],
    deny: ["bash", 1, %{}, [""], ["bad\0tool"], [123], [nil]],
    blocked_tools: ["bash", [""], ["a b"], [false]],
    require_approval: ["write", [:write, 1], [String.duplicate("x", 257)]],
    approvals: [[], "always", %{"bash" => :unsupported}, %{"bash" => "maybe"}, %{"" => :always}],
    approval_mode: ["sometimes", :root, 1, true],
    no_reply: ["true", 1, nil],
    profile: ["root", :superuser, "", 1, "FULL_ACCESS", "read-only"],
    allowed_commands: ["git", [""], ["git\nstatus"], [1]],
    blocked_commands: ["rm -rf", [" "], [nil]],
    max_file_size: [0, -1, "10", 1.5],
    workspace_read_exempt: ["yes", 1]
  }

  describe "malformed supplied policy (#71)" do
    test "every policy field rejects malformed atom- and string-keyed values and fails closed" do
      for {field, values} <- @malformed_fields,
          value <- values,
          key <- [field, Atom.to_string(field)] do
        assert_fails_closed(%{key => value})
        # A valid sibling field never rescues a malformed one.
        assert_fails_closed(Map.put(%{key => value}, sibling_key(key), ["read"]))
      end
    end

    test "unknown fields, conflicting key forms and non-map input fail closed" do
      for policy <- [
            %{"files" => true},
            %{sandbox_mode: false},
            %{{:allow} => :all},
            %{"allow" => ["read"], allow: ["read", "bash"]},
            %{"deny" => [], deny: ["bash"]},
            %{"approvals" => %{"bash" => "always"}, approvals: %{}},
            %{approvals: %{"bash" => :always, bash: :never}},
            ["read"],
            {:allow, :all},
            123,
            true,
            false,
            "root",
            :superuser,
            "",
            " full_access_but_not ",
            %URI{}
          ] do
        assert_fails_closed(policy)
      end
    end

    test "absent policy is distinguished from malformed supplied policy" do
      assert {:error, :policy_absent} = ToolPolicy.parse(nil)
      assert {:ok, _} = ToolPolicy.resolve(nil, ToolPolicy.from_profile(:read_only))

      for malformed <- [%{"allow" => 123}, %{profile: "root"}, false, []] do
        assert {:error, reason} = ToolPolicy.parse(malformed)
        refute reason == :policy_absent

        assert {:error, ^reason} =
                 ToolPolicy.resolve(malformed, ToolPolicy.from_profile(:full_access))
      end
    end

    property "unknown profile names never become full access" do
      known = Enum.map(@profiles, &Atom.to_string/1)

      check all(
              name <- string(:printable, min_length: 0, max_length: 24),
              String.trim(name) not in known
            ) do
        for form <- [name, %{"profile" => name}, %{profile: name}] do
          assert_fails_closed(form)
        end

        policy = ToolPolicy.from_profile(name)
        assert policy == ToolPolicy.deny_all()
        refute Enum.any?(@tools, &ToolPolicy.allowed?(policy, &1))
      end
    end

    test "valid profiles parse identically from atom, string, and atom/string-keyed maps" do
      for profile <- @profiles do
        name = Atom.to_string(profile)
        expected = ToolPolicy.from_profile(profile)

        for form <- [profile, name, " #{name} ", %{profile: profile}, %{"profile" => name}] do
          assert {:ok, ^expected} = ToolPolicy.parse(form)
        end

        assert {:ok, ^expected} = ToolPolicy.fetch_profile(profile)
      end
    end

    test "explicitly selected full access remains full access" do
      for form <- [
            :full_access,
            "full_access",
            %{profile: :full_access},
            %{"profile" => "full_access", "allow" => "all"},
            %{allow: :all},
            %{"allow" => "all"},
            %{}
          ] do
        assert {:ok, policy} = ToolPolicy.parse(form)
        assert policy.allow == :all
        assert policy.allowed_commands == :all

        for tool <- @tools do
          assert ToolPolicy.allowed?(policy, tool)
          assert ToolPolicy.denial_reason(policy, tool) == nil
        end

        refute ToolPolicy.requires_approval?(policy, "read")
      end
    end
  end

  describe "projections and intersections never increase authority (#72)" do
    property "valid policies keep identical authority through every projection" do
      check all(input <- valid_policy()) do
        assert {:ok, policy} = ToolPolicy.parse(input)

        transported = policy |> ToolPolicy.to_map() |> Jason.encode!() |> Jason.decode!()
        assert {:ok, ^policy} = ToolPolicy.parse(transported)
        assert {:ok, ^policy} = input |> ToolPolicy.expand() |> ToolPolicy.parse()
        assert {:ok, ^policy} = input |> ToolPolicy.atomize() |> ToolPolicy.parse()
        assert {:ok, ^policy} = ToolPolicy.validate(policy)
        assert ToolPolicy.validated?(policy)

        case ToolPolicy.normalize(input) do
          {:ok, sparse} ->
            assert {:ok, ^policy} = sparse |> Jason.encode!() |> Jason.decode!() |> parse_sparse()

          # Durable admission projections refuse conditional `dangerous` gates.
          {:error, {:invalid_field, :tool_policy}} ->
            assert Enum.any?(policy.approvals, fn {_tool, mode} -> mode == :dangerous end)
        end

        assert ToolPolicy.subset?(policy, input)
        assert ToolPolicy.subset?(input, policy)
      end
    end

    property "intersection and restriction never authorize beyond either input" do
      check all(
              floor <- valid_policy(),
              overlay <- one_of([constant(nil), valid_policy(), malformed_policy()]),
              max_runs: 300
            ) do
        case ToolPolicy.parse(overlay || %{}) do
          {:ok, requested} ->
            floor_policy = ToolPolicy.parse!(floor)

            for result <- [
                  ToolPolicy.intersect(floor, overlay),
                  ToolPolicy.intersect(overlay, floor)
                ] do
              assert {:ok, parsed} = ToolPolicy.parse(result)
              assert_subset(parsed, [floor_policy, requested])
              assert_within_gates(parsed, [floor, requested])
            end

            assert {:ok, layered} = ToolPolicy.layer(floor, requested)
            assert_subset(layered, [floor_policy, requested])
            assert_within_gates(layered, [floor, requested])

            # Delegation: the result is strictly within the parent, read
            # exemption included; an unset request inherits it.
            assert {:ok, restricted} = ToolPolicy.restrict(floor, requested)
            assert ToolPolicy.subset?(restricted, floor_policy)
            assert_subset(restricted, [requested])
            assert_within_gates(restricted, [floor, requested])

            if floor_policy.workspace_read_exempt != true,
              do: refute(restricted.workspace_read_exempt)

          {:error, _reason} ->
            # A malformed overlay is rejected, never treated as absent.
            assert {:error, _} = ToolPolicy.restrict(floor, overlay)

            for result <- [
                  ToolPolicy.intersect(floor, overlay),
                  ToolPolicy.intersect(overlay, floor)
                ],
                tool <- @tools do
              refute ToolPolicy.allowed?(result, tool)
            end
        end
      end
    end

    property "a configured approval-mode default never weakens an explicit policy" do
      check all(
              input <- valid_policy(),
              mode <- member_of([nil, :ask, :write, :yolo, "ask", "write", "yolo"])
            ) do
        policy = ToolPolicy.parse!(input)
        defaulted = ToolPolicy.with_default_approval_mode(input, mode)

        if policy.approval_mode, do: assert(defaulted.approval_mode == policy.approval_mode)

        for tool <- @tools do
          assert ToolPolicy.allowed?(defaulted, tool) == ToolPolicy.allowed?(policy, tool)

          if ToolPolicy.requires_approval?(policy, tool),
            do: assert(ToolPolicy.requires_approval?(defaulted, tool))
        end
      end
    end
  end

  defp assert_fails_closed(policy) do
    assert {:error, reason} = ToolPolicy.parse(policy), "accepted #{inspect(policy)}"
    refute reason == :policy_absent
    assert {:error, _} = ToolPolicy.validate(policy)
    assert {:error, _} = ToolPolicy.normalize(policy)
    assert {:error, _} = ToolPolicy.restrict(ToolPolicy.from_profile(:full_access), policy)
    assert {:error, _} = ToolPolicy.restrict(policy, ToolPolicy.from_profile(:full_access))
    refute ToolPolicy.validated?(policy)
    refute ToolPolicy.subset?(policy, ToolPolicy.from_profile(:full_access))
    assert ToolPolicy.expand(policy) == Map.from_struct(ToolPolicy.deny_all())
    assert ToolPolicy.apply_policy(policy, Enum.map(@tools, &%{name: &1})) == []
    assert ToolPolicy.apply_policy_to_map(policy, Map.new(@tools, &{&1, &1})) == %{}
    assert {[], _denied} = ToolPolicy.partition_tools(policy, Enum.map(@tools, &%{name: &1}))
    refute policy |> Config.parse_tool_policy() |> ToolPolicy.allowed?("read")

    for tool <- @tools do
      refute ToolPolicy.allowed?(policy, tool)
      assert ToolPolicy.requires_approval?(policy, tool)
      assert ToolPolicy.approval_mode(policy, tool) == :always
      assert ToolPolicy.denial_reason(policy, tool) == "Tool policy is invalid"

      for other <- [nil, %{}, ToolPolicy.from_profile(:full_access)] do
        refute ToolPolicy.allowed?(ToolPolicy.intersect(other, policy), tool)
        refute ToolPolicy.allowed?(ToolPolicy.intersect(policy, other), tool)
      end
    end
  end

  defp assert_subset(result, sources) do
    for source <- sources do
      assert ToolPolicy.subset?(result, neutral_read_exemption(source, result))
    end
  end

  # Every tool the result grants is granted by each source, and every approval
  # gate a source applies at any tier (the tier depends on call arguments and
  # tool source) still applies to the result at that tier.
  defp assert_within_gates(result, sources) do
    for tool <- @tools, ToolPolicy.allowed?(result, tool), source <- sources do
      assert ToolPolicy.allowed?(source, tool)

      for tier <- [:read, :write, :exec],
          ToolPolicy.requires_approval?(source, tool, %{}, tier),
          do: assert(ToolPolicy.requires_approval?(result, tool, %{}, tier))
    end
  end

  # An unset `workspace_read_exempt` inherits (restrict) or is neutral (layer),
  # while `subset?/2` ranks nil below true, so compare against the side resolved
  # to the result's value when it is unset.
  defp neutral_read_exemption(%{workspace_read_exempt: nil} = requested, restricted),
    do: %{requested | workspace_read_exempt: restricted.workspace_read_exempt}

  defp neutral_read_exemption(requested, _restricted), do: requested

  defp sibling_key(key) when is_atom(key), do: if(key == :allow, do: :deny, else: :allow)
  defp sibling_key(key), do: if(key == "allow", do: "deny", else: "allow")

  # Sparse durable projections are string-keyed JSON; an absent profile is custom.
  defp parse_sparse(sparse), do: ToolPolicy.parse(sparse)

  defp valid_policy do
    gen all(
          fields <-
            optional_map(%{
              allow: one_of([constant(:all), constant("all"), tool_list()]),
              deny: tool_list(),
              blocked_tools: tool_list(),
              require_approval: tool_list(),
              approvals: approvals(),
              approval_mode: member_of([nil, :ask, :write, :yolo, "ask", "write", "yolo"]),
              no_reply: boolean(),
              profile:
                one_of([
                  constant(nil),
                  member_of(@profiles),
                  map(member_of(@profiles), &Atom.to_string/1)
                ]),
              allowed_commands:
                one_of([
                  constant(:all),
                  list_of(member_of(["git status", "mix test"]), max_length: 2)
                ]),
              blocked_commands: list_of(member_of(["rm -rf", "sudo"]), max_length: 2),
              max_file_size: one_of([constant(nil), positive_integer()]),
              workspace_read_exempt: member_of([nil, true, false])
            }),
          string_keys? <- boolean()
        ) do
      if string_keys?, do: Map.new(fields, fn {k, v} -> {Atom.to_string(k), v} end), else: fields
    end
  end

  defp malformed_policy do
    fields = Map.to_list(@malformed_fields)

    gen all(
          base <- valid_policy(),
          {field, values} <- member_of(fields),
          value <- member_of(values)
        ) do
      key = if Enum.any?(Map.keys(base), &is_binary/1), do: Atom.to_string(field), else: field

      base
      |> Map.drop([field, Atom.to_string(field)])
      |> Map.put(key, value)
    end
  end

  defp tool_list do
    list_of(one_of([member_of(@tools), map(member_of(@tools), &String.to_atom/1)]),
      max_length: 4
    )
  end

  # Later entries for the same tool replace earlier ones, so keys stay unique.
  defp approvals do
    modes = [:always, "always", :never, "never", :dangerous, "dangerous", true, false]
    map(list_of(tuple({member_of(@tools), member_of(modes)}), max_length: 3), &Map.new/1)
  end
end
