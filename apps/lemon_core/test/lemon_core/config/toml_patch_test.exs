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
end
