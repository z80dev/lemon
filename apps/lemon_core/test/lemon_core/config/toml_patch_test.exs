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
end
