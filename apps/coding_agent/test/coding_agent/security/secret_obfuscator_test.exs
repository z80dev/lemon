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
    # Invalid entries are skipped individually with a warning.
    assert log =~ ~s(type must be "plain" or "regex")
    assert log =~ "invalid regex pattern"
    assert log =~ "can never be redacted"

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
    assert SecretObfuscator.obfuscate(build(ctx, %{}), "token=#{token}") == out

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
