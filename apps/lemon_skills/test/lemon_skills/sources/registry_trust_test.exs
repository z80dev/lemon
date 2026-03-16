defmodule LemonSkills.Sources.RegistryTrustTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Sources.Registry

  describe "trust_for_ref/1 - namespace-derived trust" do
    test "official/ namespace yields :official trust" do
      assert Registry.trust_for_ref("official/devops/k8s-rollout") == :official
    end

    test "community/ namespace yields :community trust" do
      assert Registry.trust_for_ref("community/tools/my-skill") == :community
    end

    test "unknown namespace yields :community trust (safe default)" do
      assert Registry.trust_for_ref("acme/tools/my-skill") == :community
    end
  end

  describe "trust_level/0 - module default" do
    test "default trust_level/0 is :official (for official/ refs)" do
      assert Registry.trust_level() == :official
    end
  end
end
