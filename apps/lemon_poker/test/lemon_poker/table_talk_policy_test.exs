defmodule LemonPoker.TableTalkPolicyTest do
  use ExUnit.Case, async: true

  alias LemonPoker.TableTalkPolicy

  test "blocks action commentary during live hand" do
    assert {:block, :strategy_commentary_during_live_hand} =
             TableTalkPolicy.evaluate("nice bet sizing", true)
  end

  test "blocks explicit short-card reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("I have Ah Ks lol", true)
  end

  test "blocks pocket-pair reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("I folded pocket aces", true)
  end

  test "blocks first-person past-tense hole-card reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("I had ace king", true)
  end

  test "blocks shorthand combo reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("AKo no fear", true)
  end

  test "blocks numeric shorthand combo reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("92o from early position? I'm not that brave.", true)
  end

  test "blocks offsuit shorthand reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("Q2 off-suit, already in for the blind.", true)
  end

  test "blocks folded shorthand reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("I folded A K offsuit", true)
  end

  test "blocks spaced short-card reveal during live hand" do
    assert {:block, :card_reveal_during_live_hand} =
             TableTalkPolicy.evaluate("I got A h and K d", true)
  end

  test "blocks hand-strength commentary during live hand" do
    assert {:block, :strategy_commentary_during_live_hand} =
             TableTalkPolicy.evaluate("Top pair, top kicker.", true)
  end

  test "blocks live action commentary during live hand" do
    assert {:block, :strategy_commentary_during_live_hand} =
             TableTalkPolicy.evaluate("You bet into me, I'll pay to see the turn.", true)
  end

  test "allows social banter during live hand" do
    assert :allow = TableTalkPolicy.evaluate("good luck everybody, fun table today", true)
  end

  test "allows same content after hand is not live" do
    assert :allow = TableTalkPolicy.evaluate("I had Ah Ks", false)
  end

  test "empty talk is blocked" do
    assert {:block, :empty} = TableTalkPolicy.evaluate("   ", true)
  end
end
