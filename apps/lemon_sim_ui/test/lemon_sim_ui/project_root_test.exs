defmodule LemonSimUi.ProjectRootTest do
  use ExUnit.Case, async: true

  test "resolves the umbrella root from the sim ui source tree" do
    source_dir = Path.expand("../lib/lemon_sim_ui", __DIR__)
    expected_root = Path.expand("../../../..", __DIR__)

    assert LemonSimUi.ProjectRoot.resolve(source_dir) == expected_root
  end
end
