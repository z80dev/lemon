defmodule LemonChannels.Adapters.Email.AddressTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Email.Address

  test "keeps the whole mailbox, including every legal local-part character" do
    for {input, expected} <- [
          {"o'connor@example.com", "o'connor@example.com"},
          {"O'Connor <O'Connor@Example.com>", "o'connor@example.com"},
          {"alice+tag@example.com", "alice+tag@example.com"},
          {"first.last@mail.example.co.uk", "first.last@mail.example.co.uk"},
          {"a!#$%&'*+/=?^_`{|}~-z@x.test", "a!#$%&'*+/=?^_`{|}~-z@x.test"},
          {"a@b.c", "a@b.c"},
          {~s("Smith, J" <j@x.test>), "j@x.test"},
          {"j@x.test (Jay)", "j@x.test"},
          {{"Jay", "J@X.test"}, "j@x.test"}
        ] do
      assert Address.parse(input) == expected, "parse(#{inspect(input)})"
    end
  end

  test "never extracts a substring or approximates an unsupported address" do
    for input <- [
          "x o'connor@example.com",
          "o'connor@example.com junk",
          "mallory@evil.test,owner@example.com",
          "<a@x.test> <b@x.test>",
          ~s("<owner@x.test>" <mallory@evil.test> <other@x.test>),
          "<a@x.test",
          "a@localhost",
          ".a@x.test",
          "a.@x.test",
          "a..b@x.test",
          "a@-x.test",
          "a@x.test.",
          ~s("quoted local"@x.test),
          "a@[127.0.0.1]",
          "jos\u00e9@x.test",
          "a@b\r\nBcc: c@d.test",
          String.duplicate("a", 65) <> "@x.test",
          "a@" <> String.duplicate("b.", 200) <> "test",
          "",
          "   ",
          nil,
          42
        ] do
      assert Address.parse(input) == nil, "accepted #{inspect(input)}"
    end
  end

  test "parses the display-name trick to the real mailbox" do
    assert Address.parse(~s("<owner@x.test>" <mallory@evil.test>)) == "mallory@evil.test"
    assert Address.parse(~s[(owner@x.test) <mallory@evil.test>]) == "mallory@evil.test"
  end
end
