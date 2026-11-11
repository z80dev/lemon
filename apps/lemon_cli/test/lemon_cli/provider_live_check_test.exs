defmodule LemonCli.ProviderLiveCheckTest do
  use ExUnit.Case, async: true

  alias LemonCli.ProviderLiveCheck

  describe "check/2 with :openai_codex_responses" do
    test "returns {:ok, %{check: :codex_discovery, model_ids: ids}} when model_id is in discovered models" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "synthetic-jwt-token",
        model_id: "gpt-5.1-codex",
        probe?: false,
        headers: %{}
      }

      mock_discover = fn opts ->
        assert opts[:access_token] == "synthetic-jwt-token"
        assert opts[:base_url] == "https://chatgpt.com/backend-api"
        assert opts[:timeout_ms] == 5_000
        assert opts[:force_refresh] == true

        models = [
          %{id: "gpt-5.2-codex", name: "GPT 5.2 Codex"},
          %{id: "gpt-5.1-codex", name: "GPT 5.1 Codex"}
        ]

        {:ok, models}
      end

      assert {:ok, %{check: :codex_discovery, model_ids: ids}} =
               ProviderLiveCheck.check(input, codex_discover: mock_discover)

      assert ids == ["gpt-5.1-codex", "gpt-5.2-codex"]
    end

    test "returns {:ok, %{check: :codex_discovery, model_ids: ids}} when probe? is true even if model_id is not in list" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "synthetic-jwt-token",
        model_id: "some-other-model",
        probe?: true,
        headers: %{}
      }

      mock_discover = fn _opts ->
        {:ok, [%{id: "gpt-5.1-codex"}]}
      end

      assert {:ok, %{check: :codex_discovery, model_ids: ["gpt-5.1-codex"]}} =
               ProviderLiveCheck.check(input, codex_discover: mock_discover)
    end

    test "returns {:error, {:model_unavailable, ids}} when model_id is not advertised and probe? is false" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "synthetic-jwt-token",
        model_id: "gpt-5.1-codex",
        probe?: false,
        headers: %{}
      }

      mock_discover = fn _opts ->
        {:ok, [%{id: "gpt-5.2-codex"}]}
      end

      assert {:error, {:model_unavailable, ["gpt-5.2-codex"]}} =
               ProviderLiveCheck.check(input, codex_discover: mock_discover)
    end

    test "an authoritative empty list makes the configured model unavailable" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "synthetic-jwt-token",
        model_id: "gpt-5.1-codex",
        probe?: false,
        headers: %{}
      }

      assert {:error, {:model_unavailable, []}} =
               ProviderLiveCheck.check(input, codex_discover: fn _ -> {:ok, []} end)
    end

    test "uses 10_000 ms timeout when extended: true" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "token",
        model_id: "m",
        probe?: true,
        headers: %{}
      }

      mock_discover = fn opts ->
        assert opts[:timeout_ms] == 10_000
        {:ok, [%{id: "m"}]}
      end

      assert {:ok, _} =
               ProviderLiveCheck.check(input, extended: true, codex_discover: mock_discover)
    end

    test "maps authentication rejection to {:error, {:unauthorized, :openai_codex}}" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "bad-token",
        model_id: "m",
        probe?: true,
        headers: %{}
      }

      mock_discover = fn _opts -> {:error, {:authentication_rejected, 401}} end

      assert {:error, {:unauthorized, :openai_codex}} =
               ProviderLiveCheck.check(input, codex_discover: mock_discover)
    end

    test "maps transport failure to {:error, :unreachable}" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "token",
        model_id: "m",
        probe?: true,
        headers: %{}
      }

      mock_discover = fn _opts -> {:error, :transport_failure} end

      assert {:error, :unreachable} =
               ProviderLiveCheck.check(input, codex_discover: mock_discover)
    end

    test "maps http errors and invalid responses to {:error, {:check_failed, reason}}" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "token",
        model_id: "m",
        probe?: true,
        headers: %{}
      }

      for reason <- [
            {:http_error, 502},
            :invalid_discovery_response,
            :no_discovery_endpoint,
            :discovery_cache_unavailable
          ] do
        mock_discover = fn _opts -> {:error, reason} end

        assert {:error, {:check_failed, ^reason}} =
                 ProviderLiveCheck.check(input, codex_discover: mock_discover)
      end
    end

    test "maps invalid or missing chatgpt credentials to {:error, :credential_not_usable}" do
      input = %{
        api: :openai_codex_responses,
        base_url: "https://chatgpt.com/backend-api",
        api_key: "bad-token",
        model_id: "m",
        probe?: true,
        headers: %{}
      }

      for reason <- [:invalid_chatgpt_access_token, :missing_chatgpt_credentials] do
        mock_discover = fn _opts -> {:error, reason} end

        assert {:error, :credential_not_usable} =
                 ProviderLiveCheck.check(input, codex_discover: mock_discover)
      end
    end
  end

  describe "failure_message/1 and doctor_failure_message/1" do
    test "formats unauthorized for codex vs general" do
      assert ProviderLiveCheck.failure_message({:unauthorized, :openai_codex}) =~
               "Your ChatGPT login was rejected. Run `lemon setup model` to sign in again."

      assert ProviderLiveCheck.doctor_failure_message({:unauthorized, :openai_codex}) =~
               "Your ChatGPT login was rejected. Run `lemon setup model` to sign in again."

      assert ProviderLiveCheck.failure_message(:unauthorized) =~ "HTTP 401/403"
      assert ProviderLiveCheck.doctor_failure_message(:unauthorized) =~ "HTTP 401/403"
    end

    test "formats model_unavailable" do
      ids = ["gpt-5.1-codex", "gpt-5.2-codex"]

      msg = ProviderLiveCheck.failure_message({:model_unavailable, ids})
      assert msg =~ "Your ChatGPT account doesn't offer"
      assert msg =~ "Available: gpt-5.1-codex, gpt-5.2-codex"
      assert msg =~ "Run `lemon setup model` to pick one."

      doc_msg = ProviderLiveCheck.doctor_failure_message({:model_unavailable, ids})
      assert doc_msg =~ "Available: gpt-5.1-codex, gpt-5.2-codex"
    end

    test "formats check_failed" do
      msg = ProviderLiveCheck.failure_message({:check_failed, {:http_error, 503}})
      assert msg =~ "Provider verification failed: check failed (HTTP 503)."

      doc_msg = ProviderLiveCheck.doctor_failure_message({:check_failed, {:http_error, 503}})
      assert doc_msg =~ "Provider check failed (HTTP 503)."
    end
  end

  describe "format_reason/1" do
    test "formats reasons accurately" do
      assert ProviderLiveCheck.format_reason(:credential_not_usable) ==
               "the provider credential is not usable"

      assert ProviderLiveCheck.format_reason(:unreachable) == "the provider is unreachable"
      assert ProviderLiveCheck.format_reason({:http_error, 500}) == "HTTP 500"

      assert ProviderLiveCheck.format_reason({:model_unavailable, []}) ==
               "the model is not available for this account"
    end
  end
end
