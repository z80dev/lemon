defmodule LemonAiRuntime.Auth.OpenAICodexOAuthTest do
  use ExUnit.Case, async: false

  alias LemonAiRuntime.Auth.OpenAICodexOAuth

  test "resolve_access_token exposes Codex auth availability through the runtime boundary" do
    previous = System.get_env("OPENAI_CODEX_API_KEY")

    on_exit(fn ->
      if previous do
        System.put_env("OPENAI_CODEX_API_KEY", previous)
      else
        System.delete_env("OPENAI_CODEX_API_KEY")
      end
    end)

    System.put_env("OPENAI_CODEX_API_KEY", "runtime-boundary-token")

    assert OpenAICodexOAuth.resolve_access_token() == "runtime-boundary-token"
  end
end
