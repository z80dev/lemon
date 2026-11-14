defmodule LemonEvals.HarnessContractTest do
  use ExUnit.Case, async: true

  alias LemonEvals.Harness
  alias LemonEvals.Evals.LiveModel

  @moduletag :tmp_dir

  describe "run/1" do
    test "live-model checks are opt in", %{tmp_dir: tmp_dir} do
      default_report = Harness.run(cwd: tmp_dir, iterations: 2)
      default_names = Enum.map(default_report.results, & &1.name)

      for contract <- LiveModel.contracts() do
        refute Atom.to_string(contract) in default_names
      end

      live_report = Harness.run(cwd: tmp_dir, iterations: 2, live_model: true, live_api_key: "")
      live_names = Enum.map(live_report.results, & &1.name)

      for contract <- LiveModel.contracts() do
        assert Atom.to_string(contract) in live_names
      end
    end

    test "live-model evals report missing credentials without provider access", %{
      tmp_dir: tmp_dir
    } do
      for contract <- LiveModel.contracts() do
        result = apply(Harness, :"#{contract}_eval", [tmp_dir, [live_api_key: ""]])
        assert result.name == Atom.to_string(contract)
        assert result.status == :fail, "#{contract} must reject missing credentials"
        assert result.details.reason =~ "LEMON_EVAL_API_KEY"
      end
    end
  end
end
