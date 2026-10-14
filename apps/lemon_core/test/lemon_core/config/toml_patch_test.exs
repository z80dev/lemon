defmodule LemonCore.Config.TomlPatchTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.TomlPatch

  test "creates missing table and key" do
    content = ""

    patched =
      TomlPatch.upsert_string(content, "providers.github_copilot", "api_key_secret", "llm_key")

    assert patched =~ "[providers.github_copilot]"
    assert patched =~ ~s(api_key_secret = "llm_key")
  end

  test "updates existing key in table" do
    content = """
    [providers.github_copilot]
    api_key_secret = "old_key"
    """

    patched =
      TomlPatch.upsert_string(content, "providers.github_copilot", "api_key_secret", "new_key")

    assert patched =~ ~s(api_key_secret = "new_key")
    refute patched =~ ~s(api_key_secret = "old_key")
  end

  test "updates escaped raw string bytes literally without changing adjacent keys or tables" do
    content = """
    # café — configuration ✓
    [profiles.owner]
    system_prompt = "old"
    unknown = "keep"

    [profiles.other]
    system_prompt = "untouched"
    """

    value = ~S(C:\profiles\1\g{1}\0\\tail "quoted") <> "\r\n\t\b\f" <> <<1>>
    line = "system_prompt = " <> Jason.encode!(value)
    patched = TomlPatch.upsert_raw_line(content, "profiles.owner", "system_prompt", line)

    assert {:ok, decoded} = Toml.decode(patched)
    assert decoded["profiles"]["owner"]["system_prompt"] == value
    assert decoded["profiles"]["owner"]["unknown"] == "keep"
    assert decoded["profiles"]["other"]["system_prompt"] == "untouched"
    assert String.starts_with?(patched, "# café — configuration ✓\n")
  end

  test "adds missing key to existing table" do
    content = """
    [providers.github_copilot]
    base_url = "https://example.test"
    """

    patched =
      TomlPatch.upsert_string(content, "providers.github_copilot", "api_key_secret", "llm_key")

    assert patched =~ ~s(base_url = "https://example.test")
    assert patched =~ ~s(api_key_secret = "llm_key")
  end

  test "does not affect other tables" do
    content = """
    [defaults]
    provider = "openai"
    model = "openai:gpt-5"

    [providers.openai]
    api_key_secret = "llm_openai_api_key"
    """

    patched =
      TomlPatch.upsert_string(content, "providers.github_copilot", "api_key_secret", "llm_key")

    assert patched =~ ~s([defaults])
    assert patched =~ ~s(provider = "openai")
    assert patched =~ ~s([providers.openai])
    assert patched =~ ~s(api_key_secret = "llm_openai_api_key")
    assert patched =~ ~s([providers.github_copilot])
  end

  test "deletes an existing key from a table" do
    content = """
    [providers.openai-codex]
    auth_source = "oauth"
    oauth_secret = "llm_openai_codex_api_key"
    api_key_secret = "legacy_secret"
    """

    patched = TomlPatch.delete_key(content, "providers.openai-codex", "api_key_secret")

    assert patched =~ ~s(auth_source = "oauth")
    assert patched =~ ~s(oauth_secret = "llm_openai_codex_api_key")
    refute patched =~ ~s(api_key_secret = "legacy_secret")
  end

  test "deletes only the selected table tree and preserves surrounding content" do
    content = """
    # keep this comment
    [profiles.alpha]
    name = "Alpha"

    [unrelated]
    unknown = "preserved"

    [profiles.alpha.runtime]
    token = "remove"

    [profiles.alphabet]
    name = "Alphabet"
    """

    patched = TomlPatch.delete_table_tree(content, "profiles.alpha")

    assert patched =~ "# keep this comment"
    assert patched =~ ~s([unrelated]\nunknown = "preserved")
    assert patched =~ ~s([profiles.alphabet]\nname = "Alphabet")
    refute patched =~ "[profiles.alpha]"
    refute patched =~ "[profiles.alpha.runtime]"
  end

  test "matches a table header spelled with quoted keys instead of appending a duplicate" do
    content = """
    [providers."openai-codex"]
    auth_source = "oauth"
    """

    patched =
      TomlPatch.upsert_string(content, "providers.openai-codex", "oauth_secret", "llm_codex")

    refute patched =~ "[providers.openai-codex]"

    assert {:ok, %{"providers" => %{"openai-codex" => %{"oauth_secret" => "llm_codex"}}}} =
             Toml.decode(patched)

    assert TomlPatch.delete_key(patched, "providers.openai-codex", "auth_source") =~
             ~s([providers."openai-codex"]\noauth_secret = "llm_codex")
  end

  test "inserts a missing parent table before its first subtable" do
    content = """
    [gateway.telegram]
    bot_token_secret = "t"
    """

    patched =
      TomlPatch.upsert_raw_line(content, "gateway", "enable_telegram", "enable_telegram = true")

    assert String.starts_with?(patched, "[gateway]\nenable_telegram = true\n\n[gateway.telegram]")

    assert {:ok, %{"gateway" => %{"enable_telegram" => true, "telegram" => _}}} =
             Toml.decode(patched)
  end

  test "edits the right bytes after non-ASCII content" do
    content = """
    # café — configuration ✓
    [defaults]
    model = "old"

    [tui]
    theme = "lemon"
    """

    patched = TomlPatch.upsert_string(content, "defaults", "model", "new")

    assert patched == String.replace(content, ~s(model = "old"), ~s(model = "new"))
  end

  test "parses dotted keys and table headers" do
    assert {:ok, ["providers", "openai-codex"]} =
             TomlPatch.parse_dotted_key(~s(providers . "openai-codex"))

    assert {:ok, ["a", "b.c"]} = TomlPatch.parse_dotted_key("a.'b.c'")
    assert :error = TomlPatch.parse_dotted_key("a..b")
    assert {:ok, ["a"]} = TomlPatch.header_path("[a] # see [b]")
    assert :error = TomlPatch.header_path("[[a]]")
  end
end
