defmodule LemonCore.RedactTest do
  use ExUnit.Case, async: true

  alias LemonCore.Redact

  defmodule Payload do
    defstruct [:api_key, :metadata]
  end

  test "credential values disappear without losing surrounding operational text" do
    secrets = [
      "sk-abcdefgh",
      "sk-ant-api03-abcdefghijklmnopqrstuv",
      "ghp_abcdefghijklmnop",
      "github_pat_abcdefghijklmnop",
      "xoxb-123456789-abcdefghijklmnop",
      "AKIA0123456789ABCDEF",
      "AIza" <> String.duplicate("a", 35),
      "eyJabcdefgh.abcdefgh.abcdefgh",
      "eyJ" <> String.duplicate("a", 40)
    ]

    for secret <- secrets,
        {left, right} <- [{"before ", " after"}, {"(\"", "\")"}, {"λ🙂 ", "\nnext"}] do
      input = left <> secret <> right
      output = Redact.text(input)
      refute output =~ secret
      assert String.starts_with?(output, left)
      assert String.ends_with?(output, right)
      assert Redact.text(output, count: true) == {output, 0}
    end
  end

  test "assignments handle separators, escaped quotes, and multi-line secret values" do
    values = [
      {"\"first second, third\"", ["first", "second", "third"]},
      {"'first second; third'", ["first", "second", "third"]},
      {"\"first\\\"second\"", ["first", "second"]},
      {"\"\"\"first\nsecond\nthird\"\"\"", ["first", "second", "third"]},
      {"unquoted-value", ["unquoted-value"]}
    ]

    for key <- ["API_KEY", "api-key", "apiKey", "access_token", "clientSecret", "passwd"],
        separator <- ["=", ": ", " = "],
        {value, fragments} <- values do
      input = "prefix #{key}#{separator}#{value}; status=ready"
      output = Redact.text(input)
      Enum.each(fragments, fn fragment -> refute output =~ fragment end)
      assert output =~ "prefix"
      assert output =~ "status=ready"
      assert Redact.text(output, count: true) == {output, 0}

      {nameless, count} = Redact.text(input, drop_keys: true, count: true)
      refute nameless =~ key
      Enum.each(fragments, fn fragment -> refute nameless =~ fragment end)
      assert count > 0
      assert Redact.text(nameless, drop_keys: true, count: true) == {nameless, 0}
    end
  end

  test "quoted JSON, embedded assignments, and authorization do not leave token suffixes" do
    for input <- [
          ~s({"api_key":"first second","status":"ready"}),
          ~s(message="api_key=first" status=ready),
          "Authorization: Bearer first.second+/= status=ready",
          ~s({"Authorization":"Bearer first.second+/=","status":"ready"}),
          "Bearer first.second+/= status=ready",
          "Authorization: Basic Zmlyc3Q6c2Vjb25k status=ready"
        ] do
      output = Redact.text(input)
      refute output =~ "first"
      refute output =~ "second"
      refute output =~ "Zmlyc3Q6c2Vjb25k"
      assert output =~ "ready"
      assert Redact.text(output) == output
    end
  end

  test "private key bodies including unfinished blocks are omitted, not just the header" do
    for kind <- ["", "RSA ", "EC ", "OPENSSH ", "ENCRYPTED "] do
      key = "-----BEGIN #{kind}PRIVATE KEY-----\nfirst-body-line\nsecond-body-line\n"
      complete = key <> "-----END #{kind}PRIVATE KEY-----"

      for value <- [key, complete] do
        output = Redact.text("before\n" <> value)
        refute output =~ "first-body-line"
        refute output =~ "second-body-line"
        assert output =~ "before"
        assert Redact.text(output, count: true) == {output, 0}
      end

      assert Redact.text(complete <> "\nafter") =~ "after"
    end
  end

  test "nested maps, structs, keyword lists and tuples cannot bypass sensitive keys" do
    input = %{
      payload: %Payload{api_key: "hidden-a", metadata: [%{"Authorization" => "hidden-b"}]},
      rows: [[password: "hidden-c", enabled: false], {:ok, %{cookie: "hidden-d"}}],
      message: "token=hidden-e",
      usage: %{input: 123, output: 456},
      missing: nil
    }

    output = Redact.map(input)
    rendered = inspect(output)
    for suffix <- ~w(a b c d e), do: refute(rendered =~ "hidden-#{suffix}")
    refute is_struct(output.payload)
    assert output.usage == input.usage
    assert output.missing == nil
    assert output.rows |> hd() |> Keyword.fetch!(:enabled) == false
    assert Redact.map(output) == output
  end

  test "strict config exports retain safe settings and omit multiline and unlabeled secrets" do
    hex = "0x" <> String.duplicate("ab", 32)

    input =
      "model = \"claude\"\nprivate = \"\"\"hidden-one\nhidden-two\"\"\"\nsession = \"hidden-three\"\n#{hex}"

    {output, count} = Redact.text(input, strict: true, count: true)

    for value <- ["hidden-one", "hidden-two", "hidden-three", hex], do: refute(output =~ value)
    assert output =~ ~s(model = "claude")
    assert count > 0
    assert Redact.text(output, strict: true, count: true) == {output, 0}
    assert Redact.text(hex) == hex
  end

  test "ordinary text and noncredential data remain useful" do
    for value <- [
          "status=ready model=claude",
          "the tokenizer uses 42 tokens",
          "basic authentication",
          "api_key =\nmodel=claude",
          "",
          nil,
          false,
          5
        ] do
      assert Redact.text(value) == value
    end

    for key <- [
          :api_key,
          "X-API-Key",
          "oauthToken",
          "client_secret",
          "password",
          "cookie",
          :mcp_servers,
          "mcp_servers_json",
          "mcpServers"
        ] do
      assert Redact.sensitive_key?(key)
    end

    for key <- [:status, "model", "session_id", "private_directory", 7, {"key", "value"}] do
      refute Redact.sensitive_key?(key)
    end
  end
end
