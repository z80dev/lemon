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

  A rotation whose key switch could not be confirmed stays pending and blocks
  secret writes and new rotations. Settle it after checking the provider:

      mix lemon.secrets.rotate_key --resume    # the provider holds the new key
      mix lemon.secrets.rotate_key --abandon --confirm-abandon

  `--abandon` asserts the earlier write was cancelled and can never land. It
  prints a warning and acts only with `--confirm-abandon`; preserve the
  current key and the secrets store first.
  """

  @usage "Usage: mix lemon.secrets.rotate_key " <>
           "[--confirm <token> | --resume | --abandon --confirm-abandon]"

  @impl true
  def run(args) do
    switches = [confirm: :string, resume: :boolean, abandon: :boolean, confirm_abandon: :boolean]
    {parsed, rest, invalid} = OptionParser.parse(args, strict: switches)

    if rest != [] or invalid != [] do
      Mix.raise(@usage)
    end

    Mix.Tasks.Lemon.Secrets.ensure_started!()
    confirmed? = parsed[:confirm_abandon] == true

    case {parsed[:confirm], parsed[:resume] == true, parsed[:abandon] == true, confirmed?} do
      {nil, false, false, false} ->
        preview()

      {token, false, false, false} ->
        rotate(token)

      {nil, true, false, false} ->
        recover(:resume, [])

      {nil, false, true, _} ->
        Mix.shell().error(KeyRotation.abandon_warning())
        recover(:abandon, confirm_abandon: confirmed?)

      _conflicting ->
        Mix.raise(@usage)
    end
  end

  defp recover(action, opts) do
    case KeyRotation.recover(action, opts) do
      {:ok, %{action: :resumed} = result} ->
        Mix.shell().info(
          "Resumed: #{format_source(result)} holds the new master key. " <>
            "Run mix lemon.secrets.rotate_key to finish re-encrypting."
        )

      {:ok, %{action: :abandoned} = result} ->
        Mix.shell().info(
          "Abandoned the pending key switch; #{format_source(result)} keeps the current key."
        )

      {:error, reason} ->
        Mix.raise(error_message(reason))
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
