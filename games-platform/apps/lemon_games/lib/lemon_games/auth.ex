defmodule LemonGames.Auth do
  @moduledoc """
  API token management for external game agents.

  Tokens are issued as `lgm_<random>` plaintext, stored by SHA-256 hash.
  """

  @table :game_agent_tokens
  @prefix "lgm_"

  @spec issue_token(map()) :: {:ok, map()}
  def issue_token(params) do
    raw = :crypto.strong_rand_bytes(24)
    plaintext = @prefix <> Base.url_encode64(raw, padding: false)
    token_hash = hash_token(plaintext)
    now = System.system_time(:millisecond)

    claims = %{
      "agent_id" => params["agent_id"],
      "owner_id" => params["owner_id"],
      "scopes" => params["scopes"] || ["games:read", "games:play"],
      "issued_at_ms" => now,
      "expires_at_ms" => now + ttl_ms(params),
      "status" => "active"
    }

    :ok = LemonCore.Store.put(@table, token_hash, claims)
    {:ok, %{token: plaintext, claims: claims, token_hash: token_hash}}
  end

  @spec validate_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_token(bearer) do
    token_hash = hash_token(bearer)

    case LemonCore.Store.get(@table, token_hash) do
      nil ->
        {:error, :invalid_token}

      claims ->
        now = System.system_time(:millisecond)

        cond do
          claims["status"] == "revoked" -> {:error, :revoked_token}
          claims["expires_at_ms"] < now -> {:error, :expired_token}
          true -> {:ok, claims}
        end
    end
  end

  @spec revoke_token(String.t()) :: :ok
  def revoke_token(token_hash) do
    case LemonCore.Store.get(@table, token_hash) do
      nil ->
        :ok

      claims ->
        LemonCore.Store.put(@table, token_hash, Map.put(claims, "status", "revoked"))
    end
  end

  @spec list_tokens(map()) :: [map()]
  def list_tokens(_opts \\ %{}) do
    @table
    |> LemonCore.Store.list()
    |> Enum.map(fn {hash, claims} ->
      Map.put(claims, "token_hash", hash)
    end)
    |> Enum.sort_by(fn c -> -(c["issued_at_ms"] || 0) end)
  end

  @spec has_scope?(map(), String.t()) :: boolean()
  def has_scope?(claims, scope) do
    scope in (claims["scopes"] || [])
  end

  defp hash_token(token) do
    Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  end

  defp ttl_ms(params) do
    hours = params["ttl_hours"] || 24 * 30
    hours * 60 * 60 * 1000
  end
end
