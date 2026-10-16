defmodule LemonCore.RedactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  @shapes [
    ~S(run 'PASSWORD=first&mode=last' now),
    ~S(x=%27PASSWORD%3Dfirst%26mode%3Dlast%27 now),
    ~S(message%20text=api_key="first second" now),
    ~S(message%20text="api_key=first second" now),
    ~S(message%20text=api_key%3D%22first%20second%22 now),
    ~S(%74oken=api_key="first second" now),
    ~S(%2574oken=first now),
    ~S(%access_key=first now),
    ~S(%bearer=first now),
    ~S(token%3Dfirst now),
    ~S(a=b&%70assword=first&c=d now)
  ]

  test "tokenizer redacts quoted, nested, and percent-encoded credential shapes" do
    for input <- @shapes do
      for opts <- [[], [drop_keys: true], [strict: true]] do
        output = Redact.text(input, opts)
        refute output =~ "first", "#{inspect(opts)} leaked: #{output}"
        refute output =~ "second"
        refute output =~ "last" and input =~ "PASSWORD"
        # Strict config exports drop whole sensitive lines by design.
        assert output =~ "now" or opts == [strict: true]
        assert Redact.text(output, Keyword.put(opts, :count, true)) == {output, 0}
      end
    end
  end

  @legacy_corpus [
    "password:hunter2?check",
    ~S(gateway?token="hidden"),
    "https://example.test/?token=hidden&mode=ok",
    "token=a&token=b&token=c",
    ~S({"api_key":"first second","status":"ready"}),
    ~S(message="api_key=first" status=ready),
    "Authorization: Bearer first.second status=ready",
    "status=ready model=claude",
    "the tokenizer uses 42 tokens",
    "api_key =\nmodel=claude",
    ~S(token="unterminated api_key='x),
    ~S(%zz=%token=x%),
    "%",
    "=:=:",
    "password=prefix%22api_key=first%22suffix"
  ]

  test "output is never less redacted than the legacy regex pass" do
    for input <- @legacy_corpus ++ @shapes, opts <- [[], [drop_keys: true], [strict: true]] do
      assert_monotonic(input, opts)
    end
  end

  test "encoded wrapper inside an outer assignment keeps the full legacy redaction" do
    input = "password=prefix%22api_key=first%22suffix"
    assert Redact.text(input) == "password=[REDACTED]"
    assert Redact.text(input, drop_keys: true) == "[REDACTED]"
  end

  property "random credential-shaped text is never less redacted than legacy" do
    fragment =
      one_of([
        member_of(~w(token api_key password message%20text %74oken %access_key %bearer status)),
        member_of(["=", ":", "%3D", "&", "'", ~S("), " ", "%22", "%27", "\\", "?", "[REDACTED]"]),
        string(:alphanumeric, max_length: 6),
        string(:printable, max_length: 4)
      ])

    check all(
            parts <- list_of(fragment, max_length: 30),
            opts <- member_of([[], [drop_keys: true], [strict: true]])
          ) do
      input = Enum.join(parts)
      assert_monotonic(input, opts)
      output = Redact.text(input, opts)
      assert Redact.text(output, opts) == output
    end
  end

  test "tokenizer is linear on adversarial long inputs" do
    for unit <- ["token=a&", "%74oken=a&", ~S('a="), ~S(token="), "password=", "a=", "%2525", ":"] do
      small = time(String.duplicate(unit, 10_000))
      large = time(String.duplicate(unit, 100_000))
      assert large < 10_000_000, "#{unit} took #{large}us"
      assert large < max(small, 1_000) * 40, "#{unit}: #{small}us -> #{large}us"
    end

    small = time(String.duplicate("%74oken%3D", 10_000) <> "secret")
    large = time(String.duplicate("%74oken%3D", 100_000) <> "secret")
    assert large < 10_000_000, "encoded chain took #{large}us"
    assert large < max(small, 1_000) * 40, "encoded chain: #{small}us -> #{large}us"
  end

  defp time(input) do
    {micros, _} = :timer.tc(fn -> Redact.text(input) end)
    micros
  end

  # The tokenizer only replaces spans of the legacy output with markers, so every
  # marker-free piece of the result appears in the legacy output, in order.
  defp assert_monotonic(input, opts) do
    legacy = Redact.text(input, Keyword.put(opts, :tokenizer, false))
    output = Redact.text(input, opts)

    output
    |> String.split("[REDACTED]", trim: true)
    |> Enum.reduce(0, fn piece, offset ->
      case :binary.match(legacy, piece, scope: {offset, byte_size(legacy) - offset}) do
        {at, size} ->
          at + size

        :nomatch ->
          flunk("#{inspect(input)} #{inspect(opts)}: #{inspect(output)} vs #{inspect(legacy)}")
      end
    end)
  end
end
