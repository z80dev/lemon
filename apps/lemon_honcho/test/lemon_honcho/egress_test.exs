defmodule LemonHoncho.EgressTest do
  @moduledoc """
  The screen every user-derived string crosses on its way to Honcho, so the
  properties under test are the ones a caller is entitled to assume without
  re-checking: the result is never longer than the budget, never a half
  character, never a credential, and never a surprise shape.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LemonHoncho.Egress

  doctest LemonHoncho.Egress

  describe "clipping" do
    test "passes short text through, trimmed" do
      assert Egress.screen("  why is the build slow?\n", 1_500) == "why is the build slow?"
    end

    test "clips to the budget it is given" do
      assert Egress.screen(String.duplicate("a", 40_000), 1_500) == String.duplicate("a", 1_500)
    end

    test "counts graphemes rather than bytes, so a clip never splits a character" do
      # 1,000 two-codepoint graphemes: a byte- or codepoint-wise cut would split
      # one of them and put half a character on the wire.
      clipped = Egress.screen(String.duplicate("é🇬🇧", 1_000), 1_500)

      assert String.length(clipped) == 1_500
      assert String.valid?(clipped)
      assert String.last(clipped) in ["é", "🇬🇧"]
      assert byte_size(clipped) > 1_500
    end

    test "trims before clipping, so leading whitespace does not eat the budget" do
      assert Egress.screen("   " <> String.duplicate("b", 10), 5) == "bbbbb"
    end
  end

  describe "withholding" do
    test "withholds text that looks like it carries a credential" do
      assert Egress.screen(secret(), 1_500) == nil
    end

    test "screens the clipped text rather than the original" do
      # The credential is past the cut, so what would actually be sent is clean
      # and withholding it would buy nothing.
      text = "why is the build slow? " <> secret()

      assert Egress.screen(text, 10) == "why is the"
    end

    test "withholds when the credential survives the clip" do
      assert Egress.screen(secret() <> String.duplicate(" tail", 500), 200) == nil
    end

    test "logs the withhold at debug and never logs the text" do
      logs = capture_log(fn -> assert Egress.screen(secret(), 1_500) == nil end)

      assert logs =~ "withheld"
      refute logs =~ "sk-live"
      refute logs =~ "api_key"
    end
  end

  describe "inputs that are not text to send" do
    test "blank text is nothing to send" do
      assert Egress.screen("", 1_500) == nil
      assert Egress.screen("   \n\t ", 1_500) == nil
    end

    test "anything that is not a binary is nothing to send" do
      assert Egress.screen(nil, 1_500) == nil
      assert Egress.screen(:query, 1_500) == nil
      assert Egress.screen(42, 1_500) == nil
      assert Egress.screen(["why", "is"], 1_500) == nil
    end

    test "a budget that is not a positive integer withholds rather than sends unbounded" do
      assert Egress.screen("why is the build slow?", 0) == nil
      assert Egress.screen("why is the build slow?", -1) == nil
      assert Egress.screen("why is the build slow?", nil) == nil
    end
  end

  # Matches `LemonMemory.Safety.contains_secret?/1` twice over: on the `api_key:`
  # assignment and on the `sk-` prefix.
  defp secret do
    "deploy is failing, my api_key: sk-live-4f9c1e2d8a7b6c5d0e9f8a7b6c5d4e3f2a1b"
  end
end
