defmodule Ai.Auth.OAuthPKCE do
  @moduledoc false

  @spec generate() :: %{verifier: String.t(), challenge: String.t()}
  def generate do
    verifier = random_bytes(32)
    challenge = :crypto.hash(:sha256, verifier) |> base64url_encode()

    %{verifier: verifier, challenge: challenge}
  end

  @spec random_state(pos_integer()) :: String.t()
  def random_state(bytes \\ 16) when is_integer(bytes) and bytes > 0 do
    random_bytes(bytes)
  end

  @spec base64url_encode(binary()) :: String.t()
  def base64url_encode(bytes) when is_binary(bytes) do
    Base.url_encode64(bytes, padding: false)
  end

  defp random_bytes(size) do
    size
    |> :crypto.strong_rand_bytes()
    |> base64url_encode()
  end
end
