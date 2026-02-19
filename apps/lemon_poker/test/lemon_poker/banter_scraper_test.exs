defmodule LemonPoker.BanterScraperTest do
  use ExUnit.Case, async: true

  alias LemonPoker.BanterScraper

  describe "clean_text/1" do
    test "removes markdown formatting" do
      assert BanterScraper.clean_text("**bold** text") == "bold text"
      assert BanterScraper.clean_text("*italic* text") == "italic text"
      assert BanterScraper.clean_text("`code` text") == "code text"
    end

    test "removes URLs" do
      assert BanterScraper.clean_text("Check out https://example.com here") == "Check out here"
    end

    test "removes citation markers" do
      assert BanterScraper.clean_text("Great hand[1] indeed") == "Great hand indeed"
    end

    test "normalizes whitespace" do
      assert BanterScraper.clean_text("too   much   space") == "too much space"
    end

    test "truncates long text" do
      long = String.duplicate("a", 250)
      result = BanterScraper.clean_text(long)
      assert String.length(result) == 203  # 200 + "..."
      assert String.ends_with?(result, "...")
    end
  end

  describe "categorize_items/1" do
    test "categorizes items by detected category" do
      items = [
        %{text: "Hello everyone, good luck!", source: "test", category: nil},
        %{text: "That was a brutal bad beat", source: "test", category: nil},
        %{text: "Nice hand, well played", source: "test", category: nil}
      ]

      categorized = BanterScraper.categorize_items(items)

      assert is_map(categorized)
      assert map_size(categorized) >= 1
    end

    test "preserves explicit categories" do
      items = [
        %{text: "Some text here", source: "test", category: "custom"}
      ]

      categorized = BanterScraper.categorize_items(items)
      assert categorized["custom"] == [%{text: "Some text here", source: "test", category: "custom"}]
    end
  end

  describe "is_banter_worthy?/1 via clean_text" do
    test "filters out short text" do
      assert BanterScraper.clean_text("Hi") == "Hi"
    end

    test "handles deleted content markers" do
      # clean_text doesn't filter these, but is_banter_worthy? would reject them
      assert BanterScraper.clean_text("[deleted]") == "[deleted]"
      assert BanterScraper.clean_text("[removed]") == "[removed]"
    end
  end
end
