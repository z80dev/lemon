defmodule CodingAgent.Security.SecretObfuscatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.Security.SecretObfuscator
  alias LemonAi.Types.{AssistantMessage, ImageContent, ThinkingContent, ToolCall}

  @placeholder ~r/\$\$(?:[A-Z0-9]+_)?[A-Z0-9]{12}(?::[ULCM])?\$\$/

  setup do
    root = Path.join(System.tmp_dir!(), "secret-obf-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    File.mkdir_p!(agent_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{cwd: cwd, agent_dir: agent_dir}
  end

  defp build(ctx, env, opts \\ []) do
    SecretObfuscator.build([cwd: ctx.cwd, agent_dir: ctx.agent_dir, env: env] ++ opts)
  end

  defp split_batches(first, second) do
    [
      [%{role: :user, content: first}, %{role: :tool_result, content: second}],
      [
        %{
          role: :user,
          content: [%{type: :text, text: first}, %{"type" => "text", "text" => second}]
        }
      ],
      [
        %{
          role: :assistant,
          content: [%{type: :text, text: first}, %{type: :thinking, thinking: second}]
        }
      ],
      [
        %{
          role: :assistant,
          content: [
            %{
              type: :tool_call,
              arguments: %{"steps" => [%{"command" => first}, %{"nested" => [second]}]}
            }
          ]
        }
      ],
      [%{role: :bash_execution, command: first, output: second}],
      [
        %{role: :branch_summary, summary: first},
        %{role: :compaction_summary, summary: second}
      ],
      [%{role: :custom, content: first}, %{role: :user, content: second}]
    ]
  end

  test "env and secrets.yml sources: precedence, modes, validation and round trip", ctx do
    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: plain
      content: shared-secret-value
      mode: replace
      replacement: "[gone]"
    - type: plain
      content: global-only-secret
      mode: replace
      replacement: "[global]"
    - type: bogus
      content: anything
    - type: regex
      content: "."
      mode: replace
    """)

    File.write!(Path.join([ctx.cwd, ".lemon", "secrets.yml"]), """
    - type: plain
      content: shared-secret-value
      friendlyName: DB Pass
    - type: regex
      content: "/akia[0-9a-z]{16}/i"
    - type: plain
      content: tiny
    - type: regex
      content: "("
    """)

    env = %{
      "GITHUB_TOKEN" => "env-token-value-1",
      "MY_PASS" => "short",
      "AUTHOR" => "authorvaluelong",
      "HINT" => "not-a-secret-but-long"
    }

    text =
      "env-token-value-1 shared-secret-value global-only-secret AKIAABCDEFGHIJKLMNOP " <>
        "tiny short authorvaluelong not-a-secret-but-long"

    {obfuscator, log} = with_log(fn -> build(ctx, env) end)
    refute log =~ "shared-secret-value"
    refute log =~ "global-only-secret"

    out = SecretObfuscator.obfuscate(obfuscator, text)

    for secret <- ["env-token-value-1", "shared-secret-value", "AKIAABCDEFGHIJKLMNOP"] do
      refute out =~ secret
    end

    # Project obfuscate entry overrides the global replace entry for the same content.
    refute out =~ "[gone]"
    assert out =~ ~r/\$\$DBPASS_[A-Z0-9]{12}:L\$\$/
    # Short values, non-secret env names (AUTH must end the name or precede `_`)
    # and the rejected match-everything regex leave ordinary text alone.
    assert out =~ "tiny short authorvaluelong not-a-secret-but-long"

    # Obfuscate mode is reversible; replace mode is one way.
    assert SecretObfuscator.deobfuscate(obfuscator, out) ==
             String.replace(text, "global-only-secret", "[global]")

    File.write!(
      Path.join([ctx.cwd, ".lemon", "secrets.yml"]),
      "- content: \"malformed-secret-value\n"
    )

    {parsed, parse_log} = with_log(fn -> build(ctx, env) end)
    refute parse_log =~ "malformed-secret-value"
    refute SecretObfuscator.obfuscate(parsed, "env-token-value-1") =~ "env-token-value-1"
  end

  test "placeholders are keyed per install, deterministic and case-hinted", ctx do
    token = "ghp_" <> String.duplicate("abc123def4", 4)
    key_path = Path.join(ctx.agent_dir, "secret-placeholder.key")

    obfuscator = build(ctx, %{})
    # Built-in token detection creates the key lazily, on first match.
    refute File.exists?(key_path)
    out = SecretObfuscator.obfuscate(obfuscator, "token=#{token}")
    assert out =~ ~r/^token=\$\$CREDENTIAL_[A-Z0-9]{12}:L\$\$$/
    assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600
    assert SecretObfuscator.deobfuscate(obfuscator, out) == "token=#{token}"

    # Stable across restarts with the same key; unrelated under another key.
    File.chmod!(key_path, 0o644)
    assert SecretObfuscator.obfuscate(build(ctx, %{}), "token=#{token}") == out
    assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600

    other_key = Path.join(ctx.agent_dir, "other.key")

    refute SecretObfuscator.obfuscate(build(ctx, %{}, key_path: other_key), "token=#{token}") ==
             out

    env = %{
      "A_KEY" => "MixedCaseSecret1",
      "B_KEY" => "UPPERCASESECRET",
      "C_KEY" => "Capitalizedsecret",
      "D_KEY" => "lowercase-secret",
      "E_KEY" => "LOWERCASE-SECRET"
    }

    obfuscator = build(ctx, env)
    hint = fn secret -> SecretObfuscator.obfuscate(obfuscator, secret) end
    assert hint.("MixedCaseSecret1") =~ ~r/:M\$\$$/
    assert hint.("UPPERCASESECRET") =~ ~r/:U\$\$$/
    assert hint.("Capitalizedsecret") =~ ~r/:C\$\$$/
    # Values differing only by case get independent bases, so a provider cannot
    # synthesize one placeholder from another by flipping the hint.
    [_, lower_base] = Regex.run(~r/\$\$([A-Z0-9]{12}):L\$\$/, hint.("lowercase-secret"))
    refute hint.("LOWERCASE-SECRET") =~ lower_base
  end

  test "restores only minted placeholders deep inside tool arguments", ctx do
    secret = "sup3r-s3cret-value"
    obfuscator = build(ctx, %{"API_KEY" => secret})
    placeholder = SecretObfuscator.obfuscate(obfuscator, secret)
    "$$" <> bare = placeholder

    args = %{
      "steps" => [%{"cmd" => "curl -H 'auth: #{placeholder}'"}, 3],
      "renamed" => "$$OTHERLABEL_" <> bare,
      "forged" => "$$SUP3RS3CRETVALUE_" <> bare,
      "unknown" => "$$ZZZZZZZZZZZZ:L$$"
    }

    restored = SecretObfuscator.restore_tool_args(obfuscator, args)
    assert restored["steps"] == [%{"cmd" => "curl -H 'auth: #{secret}'"}, 3]
    # A placeholder minted under a different friendly label still restores...
    assert restored["renamed"] == secret
    # ...but not when the label itself is secret-shaped, or the token is unknown.
    assert restored["forged"] == args["forged"]
    assert restored["unknown"] == args["unknown"]
  end

  test "overlapping literal and regex secrets are redacted without exposing fragments", ctx do
    token = "ghp_" <> String.duplicate("abc123def4", 4)
    fragment = "abc123def4"
    obfuscator = build(ctx, %{"TOKEN" => fragment})
    output = SecretObfuscator.obfuscate(obfuscator, token)
    assert Regex.match?(@placeholder, output)
    refute output =~ "ghp_"
    assert SecretObfuscator.deobfuscate(obfuscator, output) == token

    # Neither source contains the other's whole span: their union must be hidden.
    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "12345678tail"
    """)

    overlapping = build(ctx, %{"PASSWORD" => "head12345678"})
    output = SecretObfuscator.obfuscate(overlapping, "head12345678tail")
    assert Regex.match?(@placeholder, output)
    assert SecretObfuscator.deobfuscate(overlapping, output) == "head12345678tail"

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "12345678tail"
      mode: replace
      replacement: "[removed]"
    """)

    one_way = build(ctx, %{"PASSWORD" => "head12345678"})
    output = SecretObfuscator.obfuscate(one_way, "head12345678tail")
    refute output =~ "head"
    refute output =~ "tail"
    assert SecretObfuscator.deobfuscate(one_way, output) == output
  end

  test "contextual regex values cannot escape through current or cached friendly labels", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: PASSWORD
    - type: plain
      content: lowercase-private-value
      friendlyName: PASSWORD
    """)

    obfuscator = build(ctx, %{})
    cached = SecretObfuscator.obfuscate(obfuscator, "ABCDEFGH@")
    input = "lowercase-private-value ABCDEFGH@ PASSWORD@ #{cached}"
    expected = SecretObfuscator.deobfuscate(obfuscator, input)

    assert {:ok, [%{content: output}]} =
             SecretObfuscator.transform([%{role: :user, content: input}], obfuscator)

    for value <- ["lowercase-private-value", "ABCDEFGH", "PASSWORD"] do
      refute output =~ value
    end

    assert SecretObfuscator.deobfuscate(obfuscator, output) == expected
    assert SecretObfuscator.obfuscate(obfuscator, output) == output

    assert SecretObfuscator.restore_tool_args(obfuscator, %{"steps" => [%{"text" => output}]}) ==
             %{"steps" => [%{"text" => expected}]}

    # Both the cached mint and the old provider token lose unsafe labels once
    # the contextual value has been discovered, even without its `@` context.
    for input <- ["ABCDEFGH@", cached, "lowercase-private-value", "IJKLMNOP@"] do
      output = SecretObfuscator.obfuscate(obfuscator, input)
      refute output =~ "PASSWORD"

      assert SecretObfuscator.deobfuscate(obfuscator, output) ==
               SecretObfuscator.deobfuscate(obfuscator, input)

      assert SecretObfuscator.obfuscate(obfuscator, output) == output
    end
  end

  test "contextual regex values in token-shaped raw text and overlapping groups protect labels",
       ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: PASSWORD
    - type: regex
      content: "[A-Z]{8}(?=_)"
    - type: plain
      content: WORD_tail
    """)

    obfuscator = build(ctx, %{})
    original = "ABCDEFGH@ PASSWORD_tail $$PASSWORD_ZZZZZZZZZZZZ:U$$"
    output = SecretObfuscator.obfuscate(obfuscator, original)
    refute output =~ "ABCDEFGH"
    refute output =~ "PASSWORD"
    refute output =~ "tail"
    assert SecretObfuscator.deobfuscate(obfuscator, output) == original
    assert SecretObfuscator.obfuscate(obfuscator, output) == output

    # A copied live suffix cannot turn a previously matched contextual value
    # into an accepted friendly alias, or smuggle it to a provider without `@`.
    known = SecretObfuscator.obfuscate(obfuscator, "ABCDEFGH@") |> String.trim_trailing("@")
    {_, suffix} = String.split_at(known, 2)
    forged = "$$PASSWORD_" <> suffix
    assert SecretObfuscator.deobfuscate(obfuscator, forged) == forged
    output = SecretObfuscator.obfuscate(obfuscator, forged)
    refute output =~ "PASSWORD"
    assert SecretObfuscator.deobfuscate(obfuscator, output) == forged
    assert SecretObfuscator.obfuscate(obfuscator, output) == output
  end

  test "secret-bearing raw prefixes cannot bypass a one-way match", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=_)"
      mode: replace
      replacement: "[removed]"
    """)

    obfuscator = build(ctx, %{})
    input = "$$PASSWORD_ZZZZZZZZZZZZ:U$$"
    output = SecretObfuscator.obfuscate(obfuscator, input)
    refute output =~ "PASSWORD"
    assert SecretObfuscator.deobfuscate(obfuscator, output) == output
    assert SecretObfuscator.obfuscate(obfuscator, output) == output
  end

  test "new regex mints cannot claim a token-shaped raw value in the same input", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: Safe Service
    """)

    reference = build(ctx, %{})
    prospective = SecretObfuscator.obfuscate(reference, "ABCDEFGH@") |> String.trim_trailing("@")
    {_label, bare} = CodingAgent.Security.SecretObfuscator.Placeholder.split_friendly(prospective)
    renamed = "$$OTHER_" <> String.trim_leading(bare, "$$")

    for raw <- [prospective, renamed, bare] do
      obfuscator = build(ctx, %{})
      input = "ABCDEFGH@ #{raw}"
      output = SecretObfuscator.obfuscate(obfuscator, input)
      refute output =~ "ABCDEFGH"
      assert output =~ raw
      assert SecretObfuscator.deobfuscate(obfuscator, output) == input
      assert SecretObfuscator.obfuscate(obfuscator, output) == output
    end
  end

  test "one-way contextual matches remain fixed points next to protected tokens", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Za-z0-9]{8}(?=\\\\$\\\\$)"
      mode: replace
    - type: plain
      content: ordinary-private-value
    """)

    obfuscator = build(ctx, %{})
    token = SecretObfuscator.obfuscate(obfuscator, "ordinary-private-value")
    input = "ABCDEFGH#{token}"
    output = SecretObfuscator.obfuscate(obfuscator, input)
    refute output =~ "ABCDEFGH"
    assert String.ends_with?(output, token)
    assert byte_size(output) == byte_size(input)
    assert SecretObfuscator.obfuscate(obfuscator, output) == output

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Za-z0-9]{8}\\\\$\\\\$[A-Z0-9]{12}:L\\\\$\\\\$[A-Za-z0-9]{8}"
      mode: replace
    - type: plain
      content: ordinary-private-value
    """)

    spanning = build(ctx, %{})
    token = SecretObfuscator.obfuscate(spanning, "ordinary-private-value")
    input = "ABCDEFGH#{token}IJKLMNOP"
    output = SecretObfuscator.obfuscate(spanning, input)
    refute output =~ "ABCDEFGH"
    refute output =~ "IJKLMNOP"
    assert output =~ token
    assert byte_size(output) == byte_size(input)
    assert SecretObfuscator.obfuscate(spanning, output) == output
  end

  test "whole-input regex context survives protected token boundaries", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=\\\\$\\\\$)"
      friendlyName: PASSWORD
    - type: plain
      content: ordinary-private-value
      friendlyName: PASSWORD
    """)

    obfuscator = build(ctx, %{})
    cached = SecretObfuscator.obfuscate(obfuscator, "ordinary-private-value")
    input = "ABCDEFGH#{cached} PASSWORD#{cached}"
    output = SecretObfuscator.obfuscate(obfuscator, input)
    refute output =~ "ABCDEFGH"
    refute output =~ "PASSWORD"

    assert SecretObfuscator.deobfuscate(obfuscator, output) ==
             SecretObfuscator.deobfuscate(obfuscator, input)

    assert SecretObfuscator.obfuscate(obfuscator, output) == output

    # The regex spans an atomic token and raw bytes on both sides. Redact just
    # those raw bytes and preserve the existing token's restoration authority.
    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "left[A-Z]{8}\\\\$\\\\$[A-Z0-9]+_[A-Z0-9]{12}:L\\\\$\\\\$right[A-Z]{8}"
    - type: plain
      content: ordinary-private-value
      friendlyName: Safe Service
    """)

    spanning = build(ctx, %{})
    token = SecretObfuscator.obfuscate(spanning, "ordinary-private-value")
    input = "leftABCDEFGH#{token}rightIJKLMNOP"
    output = SecretObfuscator.obfuscate(spanning, input)
    refute output =~ "left"
    refute output =~ "right"
    refute output =~ "ABCDEFGH"
    refute output =~ "IJKLMNOP"

    assert SecretObfuscator.deobfuscate(spanning, output) ==
             SecretObfuscator.deobfuscate(spanning, input)

    assert SecretObfuscator.obfuscate(spanning, output) == output
  end

  test "self-overlapping literal occurrences hide their complete union", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))
    obfuscator = build(ctx, %{"API_KEY" => "ABABABAB"})
    input = "ABABABABABAB"
    output = SecretObfuscator.obfuscate(obfuscator, input)
    assert Regex.match?(~r/^\$\$[A-Z0-9]{12}:U\$\$$/, output)
    refute output =~ "ABAB"
    assert SecretObfuscator.deobfuscate(obfuscator, output) == input
    assert SecretObfuscator.obfuscate(obfuscator, output) == output
  end

  test "default replace-mode regex redaction keeps length and is a fixed point", ctx do
    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "postgres://[^\\\\s]+"
      mode: replace
    """)

    obfuscator = build(ctx, %{})
    url = "postgres://admin:pw@db/prod"
    out = SecretObfuscator.obfuscate(obfuscator, "use #{url} now")

    assert [_, redacted] = Regex.run(~r/^use (\S+) now$/, out)
    assert String.length(redacted) == String.length(url)
    refute out =~ "admin:pw"
    refute out =~ @placeholder
    assert SecretObfuscator.obfuscate(obfuscator, out) == out
    assert SecretObfuscator.deobfuscate(obfuscator, out) == out
  end

  test "provider batches protect earlier labels against later contextual regex values", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: PASSWORD
    """)

    for messages <- split_batches("ABCDEFGH@", "PASSWORD@") do
      obfuscator = build(ctx, %{})
      assert {:ok, output} = SecretObfuscator.transform(messages, obfuscator)
      bytes = Jason.encode!(output)
      refute bytes =~ "ABCDEFGH"
      refute bytes =~ "PASSWORD"
      assert SecretObfuscator.restore_tool_args(obfuscator, output) == messages
      assert SecretObfuscator.transform(output, obfuscator) == {:ok, output}
    end

    # Collect values across the batch, not regex context across separate fields.
    reference = SecretObfuscator.obfuscate(build(ctx, %{}), "ABCDEFGH@")

    messages = [
      %{role: :user, content: "ABCDEFGH@"},
      %{role: :user, content: "PASSWORD"},
      %{role: :user, content: "@"}
    ]

    obfuscator = build(ctx, %{})
    assert {:ok, output} = SecretObfuscator.transform(messages, obfuscator)
    assert output == [Map.put(hd(messages), :content, reference) | tl(messages)]
    assert SecretObfuscator.restore_tool_args(obfuscator, output) == messages
  end

  test "provider batches reserve later raw tokens before any earlier mint", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: Safe Service
    """)

    reference = build(ctx, %{})
    prospective = SecretObfuscator.obfuscate(reference, "ABCDEFGH@") |> String.trim_trailing("@")
    {_label, bare} = CodingAgent.Security.SecretObfuscator.Placeholder.split_friendly(prospective)
    renamed = "$$OTHER_" <> String.trim_leading(bare, "$$")

    for raw <- [prospective, renamed, bare],
        messages <- split_batches("ABCDEFGH@", raw) do
      obfuscator = build(ctx, %{})
      assert SecretObfuscator.deobfuscate(obfuscator, raw) == raw
      assert {:ok, output} = SecretObfuscator.transform(messages, obfuscator)
      refute Jason.encode!(output) =~ "ABCDEFGH"
      assert SecretObfuscator.deobfuscate(obfuscator, raw) == raw
      assert SecretObfuscator.restore_tool_args(obfuscator, output) == messages
      assert SecretObfuscator.transform(output, obfuscator) == {:ok, output}
    end
  end

  test "batch precollection excludes system text, images, metadata and argument keys", ctx do
    File.write!(Path.join(ctx.agent_dir, "secret-placeholder.key"), String.duplicate("k", 43))

    File.write!(Path.join(ctx.agent_dir, "secrets.yml"), """
    - type: regex
      content: "[A-Z]{8}(?=@)"
      friendlyName: PASSWORD
    """)

    reference = build(ctx, %{})
    prospective = SecretObfuscator.obfuscate(reference, "ABCDEFGH@") |> String.trim_trailing("@")
    assert CodingAgent.Security.SecretObfuscator.Placeholder.split_friendly(prospective) != nil
    excluded = "#{prospective} PASSWORD@"
    image = %ImageContent{data: excluded, mime_type: "image/png"}
    system = %{role: :system, content: excluded}
    metadata = %{"raw_token" => prospective, "value" => "PASSWORD@"}
    user = %{role: :user, content: [%{type: :text, text: "ABCDEFGH@"}, image], metadata: metadata}

    assistant = %{
      role: :assistant,
      content: [%{type: :tool_call, arguments: %{"PASSWORD@" => "ordinary", "opaque" => image}}]
    }

    obfuscator = build(ctx, %{})

    assert {:ok, [^system, output, ^assistant]} =
             SecretObfuscator.transform([system, user, assistant], obfuscator)

    assert output == %{user | content: [%{type: :text, text: prospective <> "@"}, image]}
  end

  test "transform rewrites assistant replay text and drops changed thinking signatures", ctx do
    secret = "thinking-secret-42"
    obfuscator = build(ctx, %{"SOME_TOKEN" => secret})

    assistant = %AssistantMessage{
      content: [
        %ThinkingContent{thinking: "I saw #{secret}", thinking_signature: "sig-a"},
        %ThinkingContent{thinking: "nothing sensitive", thinking_signature: "sig-b"},
        %ToolCall{id: "t1", name: "bash", arguments: %{"command" => "echo #{secret}"}}
      ]
    }

    image = %LemonAi.Types.UserMessage{
      content: [%ImageContent{data: secret, mime_type: "image/png"}]
    }

    assert {:ok, [out, ^image]} = SecretObfuscator.transform([assistant, image], obfuscator)

    [changed, unchanged, call] = out.content
    refute changed.thinking =~ secret
    assert changed.thinking_signature == nil
    assert unchanged.thinking_signature == "sig-b"
    refute call.arguments["command"] =~ secret
  end
end
