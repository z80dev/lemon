defmodule Mix.Tasks.Lemon.Secrets.RotateKey do
  use Mix.Task

  alias LemonCore.Secrets.KeyRotation

  @shortdoc "Rotate the secrets master key and re-encrypt stored secrets"
  @moduledoc """
  Replaces the secrets master key and re-encrypts every stored secret under it.

  Without options the task only previews: it checks that every stored secret
  decrypts with the current key and prints a confirmation token bound to the
  exact set of secrets. Apply with that token:

      mix lemon.secrets.rotate_key
      mix lemon.secrets.rotate_key --confirm <token>

  The token is refused when any secret changed since the preview, and the
  rotation is refused while a Lemon runtime is running (it keeps using the key
  it loaded at boot) or another rotation or secret write holds the secrets
  lock. See `LemonCore.Secrets.KeyRotation` for the crash-safety guarantees.
  """

  @impl true
  def run(args) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [confirm: :string])

    if rest != [] or invalid != [] do
      Mix.raise("Usage: mix lemon.secrets.rotate_key [--confirm <token>]")
    end

    Mix.Tasks.Lemon.Secrets.ensure_started!()

    case parsed[:confirm] do
      nil -> preview()
      token -> rotate(token)
    end
  end

  defp preview do
    case KeyRotation.preview() do
      {:ok, preview} ->
        Mix.shell().info("""
        Secrets master key rotation preview (nothing changed)
        key source: #{format_source(preview)}
        secrets to re-encrypt: #{preview.count}
        expired secrets to delete: #{preview.expired}
        resumed from an interrupted rotation: #{preview.resumed}
        confirmation token: #{preview.confirmation_token}

        Apply with: mix lemon.secrets.rotate_key --confirm #{preview.confirmation_token}\
        """)

        if preview.runtime_running do
          Mix.shell().info("A Lemon runtime is running; stop it before rotating.")
        end

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp rotate(token) do
    case KeyRotation.rotate(token) do
      {:ok, result} ->
        Mix.shell().info(
          "Rotated secrets master key in #{format_source(result)}: " <>
            "#{result.rotated} secrets re-encrypted, #{result.pruned} expired deleted"
        )

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp format_source(%{source: :file, key_file: path}) when is_binary(path), do: "file (#{path})"
  defp format_source(%{source: source}), do: to_string(source)

  defp error_message(reason),
    do: "Secrets key rotation failed: " <> KeyRotation.describe_error(reason)
end
