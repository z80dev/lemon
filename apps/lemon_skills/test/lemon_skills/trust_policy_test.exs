defmodule LemonSkills.TrustPolicyTest do
  @moduledoc """
  Tests for the TrustPolicy module (M4-03).

  Verifies audit and approval rules for each trust tier.
  """
  use ExUnit.Case, async: true

  alias LemonSkills.TrustPolicy

  describe "requires_audit?/1" do
    test "community skills require audit" do
      assert TrustPolicy.requires_audit?(:community)
    end

    test "builtin skills skip audit" do
      refute TrustPolicy.requires_audit?(:builtin)
    end

    test "official skills skip audit" do
      refute TrustPolicy.requires_audit?(:official)
    end

    test "trusted skills skip audit" do
      refute TrustPolicy.requires_audit?(:trusted)
    end

    test "nil (no trust recorded) requires audit" do
      assert TrustPolicy.requires_audit?(nil)
    end
  end

  describe "auto_approve?/1" do
    test "builtin skills are auto-approved" do
      assert TrustPolicy.auto_approve?(:builtin)
    end

    test "official skills require approval" do
      refute TrustPolicy.auto_approve?(:official)
    end

    test "trusted skills require approval" do
      refute TrustPolicy.auto_approve?(:trusted)
    end

    test "community skills require approval" do
      refute TrustPolicy.auto_approve?(:community)
    end

    test "nil requires approval" do
      refute TrustPolicy.auto_approve?(nil)
    end
  end

  describe "label/1" do
    test "returns human-readable labels for all levels" do
      assert TrustPolicy.label(:builtin) == "Built-in"
      assert TrustPolicy.label(:official) == "Official"
      assert TrustPolicy.label(:trusted) == "Trusted"
      assert TrustPolicy.label(:community) == "Community"
      assert TrustPolicy.label(nil) == "Unknown"
    end
  end

  describe "description/1" do
    test "returns non-empty descriptions for all levels and nil" do
      for level <- [:builtin, :official, :trusted, :community, nil] do
        desc = TrustPolicy.description(level)
        assert is_binary(desc), "description(#{inspect(level)}) should be a string"
        assert String.length(desc) > 0, "description(#{inspect(level)}) should not be empty"
      end
    end

    test "builtin description mentions bundled or application" do
      desc = TrustPolicy.description(:builtin)
      assert desc =~ "bundled" or desc =~ "application" or desc =~ "Lemon"
    end

    test "official description mentions official or registry" do
      desc = TrustPolicy.description(:official)
      assert desc =~ "official" or desc =~ "registry" or desc =~ "curated"
    end

    test "community description mentions audit or third-party" do
      desc = TrustPolicy.description(:community)
      assert desc =~ "audit" or desc =~ "third-party" or desc =~ "third party"
    end
  end

  describe "policy consistency" do
    test "only builtin is both no-audit and auto-approve" do
      all_levels = [:builtin, :official, :trusted, :community]

      combined_bypass =
        Enum.filter(all_levels, fn level ->
          not TrustPolicy.requires_audit?(level) and TrustPolicy.auto_approve?(level)
        end)

      assert combined_bypass == [:builtin],
             "Only :builtin should skip both audit and approval; got #{inspect(combined_bypass)}"
    end

    test "community is the only level requiring audit" do
      all_levels = [:builtin, :official, :trusted, :community]

      audited = Enum.filter(all_levels, &TrustPolicy.requires_audit?/1)

      assert audited == [:community],
             "Only :community should require audit; got #{inspect(audited)}"
    end
  end
end
