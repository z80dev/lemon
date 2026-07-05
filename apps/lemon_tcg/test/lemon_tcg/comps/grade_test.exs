defmodule LemonTcg.Comps.GradeTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Comps.Grade

  test "parses grading company and grade from listing names" do
    assert Grade.parse("Charizard Base Set PSA 9") == {:psa, 9.0}
    assert Grade.parse("Pikachu Illustrator PSA 10") == {:psa, 10.0}
    assert Grade.parse("Blastoise BGS-9.5 quad") == {:bgs, 9.5}
    assert Grade.parse("Umbreon Gold Star CGC 10 Pristine") == {:cgc, 10.0}
    assert Grade.parse("sgc 10 Lugia Neo Genesis") == {:sgc, 10.0}
    assert Grade.parse("Charizard VMAX raw") == :ungraded
    assert Grade.parse(nil) == :ungraded
  end

  test "does not misread card numbers as grades" do
    assert Grade.parse("Charizard #4/102 holo") == :ungraded
  end

  test "maps parsed grades to comp buckets" do
    assert Grade.bucket(:ungraded) == "ungraded"
    assert Grade.bucket({:psa, 10.0}) == "psa_10"
    assert Grade.bucket({:bgs, 10.0}) == "bgs_10"
    assert Grade.bucket({:cgc, 10.0}) == "cgc_10"
    assert Grade.bucket({:sgc, 10.0}) == "sgc_10"
    assert Grade.bucket({:psa, 9.5}) == "grade_9_5"
    assert Grade.bucket({:psa, 9.0}) == "grade_9"
    assert Grade.bucket({:bgs, 8.5}) == "grade_9"
  end

  test "parse_label handles explicit labels" do
    assert Grade.parse_label("PSA 10") == {:psa, 10.0}
    assert Grade.parse_label("ungraded") == :ungraded
    assert Grade.parse_label("raw") == :ungraded
    assert Grade.parse_label("") == :ungraded
    assert Grade.parse_label(nil) == :ungraded
  end
end
