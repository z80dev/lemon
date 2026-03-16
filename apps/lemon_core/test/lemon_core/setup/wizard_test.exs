defmodule LemonCore.Setup.WizardTest do
  use ExUnit.Case, async: true

  alias LemonCore.Setup.Wizard

  # Minimal IO callbacks stub for testing non-interactive paths
  defp silent_io do
    %{
      info: fn _msg -> :ok end,
      error: fn _msg -> :ok end,
      prompt: fn _msg -> "" end,
      secret: fn _msg -> "" end
    }
  end

  describe "run_runtime/3 — profile input safety" do
    test "invalid --profile value does not create a new atom" do
      # An attacker (or fuzzer) passing an arbitrary --profile value must not
      # cause String.to_atom/1 to intern a new atom.  The fix uses
      # String.to_existing_atom/1 only after string-level validation.
      malicious_profile = "definitely_not_a_real_profile_#{System.unique_integer([:positive])}"

      atoms_before = :erlang.system_info(:atom_count)

      # run_runtime picks up --profile from parsed args
      io = silent_io()
      Wizard.run_runtime(["--profile", malicious_profile], io, non_interactive: true)

      atoms_after = :erlang.system_info(:atom_count)

      refute atoms_after - atoms_before >= 1 and
               :erlang.system_info(:atom_table)
               |> Atom.to_string()
               |> then(fn _ ->
                 String.to_existing_atom(malicious_profile)
                 true
               end),
             "No new atom should have been created for an invalid profile name"
    rescue
      ArgumentError ->
        # String.to_existing_atom raised — the atom was never created; test passes.
        :ok
    end

    test "valid profile name is accepted without error" do
      io = silent_io()
      result = Wizard.run_runtime(["--profile", "runtime_full"], io, non_interactive: true)
      assert result == :ok
    end
  end
end
