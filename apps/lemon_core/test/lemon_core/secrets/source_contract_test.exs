defmodule LemonCore.Secrets.SourceContractTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.Source

  @implementations [
    LemonCore.Secrets.Source.OnePassword,
    LemonCore.Secrets.Source.Bitwarden,
    LemonCore.Secrets.Source.Command
  ]

  test "every bundled adapter implements the same read-only source contract" do
    Enum.each(@implementations, fn module ->
      assert Source in (module.module_info(:attributes)[:behaviour] || [])
      assert function_exported?(module, :fetch, 2)
      assert function_exported?(module, :configured?, 1)
      assert function_exported?(module, :bootstrap_ready?, 2)
    end)
  end

  test "contract error vocabulary is fixed and value-free" do
    allowed = [
      :binary_missing,
      :bootstrap_secret_missing,
      :exit_nonzero,
      :invalid_config,
      :invalid_output,
      :not_found,
      :output_too_large,
      :source_supervisor_unavailable,
      :spawn_failed,
      :timeout
    ]

    Enum.each(allowed, fn reason ->
      assert is_atom(reason)
      refute Atom.to_string(reason) =~ "secret-value"
    end)
  end
end
