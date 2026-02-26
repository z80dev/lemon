defmodule CodingAgent.Utils.HttpTest do
  use ExUnit.Case
  alias CodingAgent.Utils.Http

  describe "header_key_match?/2" do
    test "matches identical strings" do
      assert Http.header_key_match?("content-type", "content-type")
    end

    test "matches case-insensitively" do
      assert Http.header_key_match?("Content-Type", "content-type")
      assert Http.header_key_match?("CONTENT-TYPE", "content-type")
      assert Http.header_key_match?("content-type", "Content-Type")
    end

    test "matches atoms to strings" do
      assert Http.header_key_match?(:"content-type", "Content-Type")
      assert Http.header_key_match?(:"Content-Type", "content-type")
    end

    test "does not match different keys" do
      refute Http.header_key_match?("authorization", "content-type")
      refute Http.header_key_match?(:"x-custom", "x-other")
    end
  end

  describe "parse_content_type/1" do
    test "parses simple content type" do
      assert Http.parse_content_type("application/json") == {"application/json", nil}
    end

    test "parses content type with params" do
      assert Http.parse_content_type("application/json; charset=utf-8") ==
               {"application/json", "charset=utf-8"}
    end

    test "trims whitespace" do
      assert Http.parse_content_type("  text/html  ; charset=utf-8  ") ==
               {"text/html", "charset=utf-8"}
    end
  end
end
