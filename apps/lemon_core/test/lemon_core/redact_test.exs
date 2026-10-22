defmodule LemonCore.RedactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.Redact

  defmodule Payload do
    defstruct [:api_key, :metadata]
  end

  test "URL query pairs redact independently in every position" do
    for {query, expected} <- [
          {"mode=ready", "mode=ready"},
          {"session=public&mode=ready&other=unchanged",
           "session=public&mode=ready&other=unchanged"},
          {"token=hidden", "token=[REDACTED]"},
          {"token=hidden&session=public", "token=[REDACTED]&session=public"},
          {"api_key=first&session=public&password=last",
           "api_key=[REDACTED]&session=public&password=[REDACTED]"},
          {~s(token="hidden"&session=public), "token=[REDACTED]&session=public"},
          {"session=public&token=hidden&status=ready",
           "session=public&token=[REDACTED]&status=ready"},
          {"session=public&token=hidden", "session=public&token=[REDACTED]"},
          {~s(api_key="first"&session=public&password=last),
           "api_key=[REDACTED]&session=public&password=[REDACTED]"},
          {"a=b&&status=ready&", "a=b&&status=ready&"}
        ],
        prefix <- ["gateway", "https://example.test/path", "/relative/path"] do
      input = prefix <> "?" <> query
      output = prefix <> "?" <> expected
      assert Redact.text(input) == output
      assert Redact.text(output, count: true) == {output, 0}
    end

    assert Redact.text("gateway?session=public&token=hidden#section") ==
             "gateway?session=public&token=[REDACTED]"

    assert Redact.text("gateway?session=public&token=hidden", drop_keys: true) ==
             "gateway?session=public&[REDACTED]"
  end

  test "genuine query redaction is idempotent in all four modes" do
    for opts <- [[], [drop_keys: true], [strict: true], [strict: true, drop_keys: true]],
        input <- [
          "gateway?token=hidden&mode=public",
          "gateway?mode=public&session=hidden&other=ready",
          "gateway?token=\"[REDACTED]\"&mode=public",
          "gateway?token=[REDACTED]&mode=public"
        ] do
      output = Redact.text(input, opts)
      assert Redact.text(output, Keyword.put(opts, :count, true)) == {output, 0}
      assert output =~ "mode=public"
    end
  end

  test "near-miss quoted markers do not establish genuine query context" do
    for {value, default, dropped} <- [
          {~s("[REDACTED]x"), ~s(gateway?token=[REDACTED]"[REDACTED]x"&other=hidden),
           ~s(gateway?[REDACTED]"[REDACTED]x"&other=hidden)},
          {~s("x[REDACTED]"), ~s(gateway?token=[REDACTED]"x[REDACTED]"&other=hidden),
           ~s(gateway?[REDACTED]"x[REDACTED]"&other=hidden)}
        ] do
      input = "gateway?token=ab&mode=" <> value <> "&other=hidden"
      assert Redact.text(input) == default
      assert Redact.text(input, drop_keys: true) == dropped
      assert Redact.text(input, strict: true) == ~s(gateway?token="[REDACTED]")
      assert Redact.text(input, strict: true, drop_keys: true) == dropped
    end
  end

  test "unquoted sensitive-first queries retain public suffixes" do
    assert Redact.text("gateway?token=hidden&session=public") ==
             "gateway?token=[REDACTED]&session=public"

    assert Redact.text("gateway?token=hidden&session=public", drop_keys: true) ==
             "gateway?[REDACTED]&session=public"

    assert Redact.text("https://h/x?token=a&mode=1") ==
             "https://h/x?token=[REDACTED]&mode=1"
  end

  test "strict URL queries retain public pairs without relaxing config fields" do
    for {input, expected} <- [
          {"gateway?token=hidden&session=public",
           "gateway?token=\"[REDACTED]\"&session=[REDACTED]"},
          {"gateway?session=public&token=hidden&status=ready",
           "gateway?session=\"[REDACTED]\"&token=[REDACTED]&status=ready"},
          {"gateway?session=public&token=hidden",
           "gateway?session=\"[REDACTED]\"&token=[REDACTED]"},
          {"gateway?token=hidden&status=ready", "gateway?token=\"[REDACTED]\"&status=ready"},
          {"gateway?token=ab&cd", "gateway?token=\"[REDACTED]\""},
          {"session=public", "session=\"[REDACTED]\""}
        ] do
      assert Redact.text(input, strict: true) == expected
      assert Redact.text(expected, strict: true) == expected
    end
  end

  test "strict query sensitivity includes session and private in every position" do
    for key <- ["session", "private"],
        position <- 0..2,
        drop? <- [false, true],
        tokenizer? <- [false, true] do
      pairs = List.insert_at(["mode=1", "status=ready"], position, key <> "=hidden")

      replacement =
        if drop?,
          do: "[REDACTED]",
          else: key <> "=" <> if(position == 0, do: "\"[REDACTED]\"", else: "[REDACTED]")

      expected = List.replace_at(pairs, position, replacement)

      assert Redact.text("gateway?" <> Enum.join(pairs, "&"),
               strict: true,
               drop_keys: drop?,
               tokenizer: tokenizer?
             ) ==
               "gateway?" <> Enum.join(expected, "&")
    end

    assert Redact.text("https://h/x?mode=1&session=s&token=t", strict: true) ==
             "https://h/x?mode=1&session=[REDACTED]&token=[REDACTED]"
  end

  test "ordinary text and existing assignment shapes retain main's outputs" do
    for {input, expected} <- [
          {"session=public&token=private-value", "session=public&token=[REDACTED]"},
          {"token=private-value&session=public", "token=[REDACTED]"},
          {"password=ab&cd", "password=[REDACTED]"},
          {"password=&cd", "password=[REDACTED]"},
          {"env 'PASSWORD=first&mode=last' tool", "env 'PASSWORD=[REDACTED]' tool"},
          {~s(PASSWORD="first&status=ready"), "PASSWORD=[REDACTED]"},
          {"message=public&api_key=hidden", "message=public&api_key=[REDACTED]"},
          {"session=public;token=hidden", "session=public;token=[REDACTED]"},
          {"gateway?session=public&%74oken=hidden", "gateway?session=public&%74oken=[REDACTED]"},
          {"Is this ordinary text? Yes & no.", "Is this ordinary text? Yes & no."},
          {"status=ready model=claude", "status=ready model=claude"},
          {"token='first second'", "token=[REDACTED]"},
          {"Authorization: Bearer first.second", "Authorization: [REDACTED]"}
        ] do
      assert Redact.text(input) == expected
    end
  end

  # Cover instrumentation slows Redact by several times; keep the deadline as a
  # guard against quadratic behavior without failing under `mix test --cover`.
  @tag timeout: 40_000
  test "long queries and non-query assignments remain bounded" do
    pairs = String.duplicate("a=b&", 100_000)

    for input <- ["gateway?" <> pairs <> "token=hidden", pairs] do
      task = Task.async(fn -> Redact.text(input) end)
      output = Task.await(task, 15_000)
      assert output == String.replace(input, "token=hidden", "token=[REDACTED]")
    end
  end

  @tag timeout: 20_000
  test "repeated sensitive query pairs remain bounded" do
    task = Task.async(fn -> Redact.text("gateway?" <> String.duplicate("token=a&", 100_000)) end)

    assert Task.await(task, 15_000) ==
             "gateway?" <> String.duplicate("token=[REDACTED]&", 100_000)
  end

  test "query detection does not weaken sensitive assignments" do
    for {input, expected, without_keys} <- [
          {"password:hunter2?check", "password:[REDACTED]", "[REDACTED]"},
          {~s(gateway?token="hidden"), "gateway?token=[REDACTED]", "gateway?[REDACTED]"},
          {"gateway?token= hidden", "gateway?token= [REDACTED]", "gateway?[REDACTED]"}
        ] do
      assert Redact.text(input) == expected
      assert Redact.text(input, drop_keys: true) == without_keys
    end
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

  @main_baseline (
                   {rows, _} =
                     Code.eval_file(Path.join(__DIR__, "redact_main_baseline.exs"))

                   rows
                 )

  test "non-query assignments retain frozen main outputs in every mode" do
    for {input, opts, expected} <- @main_baseline do
      assert Redact.text(input, opts) == expected
    end
  end

  test "queries with fragments fall back to main while short URL-like tokens qualify" do
    assert Redact.text("https://h/x?token=a&mode=1#frag") ==
             "https://h/x?token=[REDACTED]"

    assert Redact.text("a?b=c&token=x") == "a?b=c&token=[REDACTED]"
  end

  test "encoded wrapper inside an outer assignment keeps the full legacy redaction" do
    input = "password=prefix%22api_key=first%22suffix"
    assert Redact.text(input) == "password=[REDACTED]"
    assert Redact.text(input, drop_keys: true) == "[REDACTED]"
  end

  property "sampled non-query inputs match a frozen main baseline" do
    check all({input, opts, expected} <- member_of(@main_baseline)) do
      assert Redact.text(input, opts) == expected
      assert Redact.text(expected, opts) == expected
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

  test "large mostly-plain multibyte text is redacted in milliseconds" do
    secret = "sk-" <> String.duplicate("a", 48)
    plain = String.duplicate("界", 100_000)

    for input <- [
          "api_key=#{secret} " <> plain,
          "api_key=#{secret} " <> plain <> " message%20text=ok",
          "status=ready model=claude " <> plain,
          plain
        ],
        opts <- [[], [drop_keys: true], [strict: true]] do
      output = Redact.text(input, opts)
      refute output =~ secret
      # Strict config exports drop whole sensitive lines by design.
      assert output =~ plain or (opts == [strict: true] and input =~ "api_key")

      micros = 1..3 |> Enum.map(fn _ -> time(input, opts) end) |> Enum.min()
      assert micros < 50_000, "#{byte_size(input)} bytes #{inspect(opts)} took #{micros}us"
    end
  end

  defp time(input, opts \\ []) do
    {micros, _} = :timer.tc(fn -> Redact.text(input, opts) end)
    micros
  end
end
