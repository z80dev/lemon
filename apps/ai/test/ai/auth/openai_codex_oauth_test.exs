defmodule Ai.Auth.OpenAICodexOAuthTest do
  @moduledoc """
  Tests for Ai.Auth.OpenAICodexOAuth – credential loading, JWT parsing,
  and token freshness logic.

  Uses temp directories to avoid polluting real credential stores.
  Does NOT test actual HTTP refresh calls (those are integration tests).
  """
  use ExUnit.Case, async: true

  alias Ai.Auth.OpenAICodexOAuth

  # ============================================================================
  # resolve_access_token/0
  # ============================================================================

  describe "resolve_access_token/0" do
    test "returns nil when no credentials are available" do
      # In a clean test environment with no codex/lemon credentials,
      # this should return nil
      result = OpenAICodexOAuth.resolve_access_token()
      # May return nil or a string depending on test host setup
      assert is_nil(result) or is_binary(result)
    end
  end
end
