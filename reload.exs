# Hot reload script for Lemon Gateway voice modules
# Run this to reload fixed modules without restarting the entire system

defmodule VoiceReloader do
  def reload do
    modules = [
      LemonGateway.Voice.DeepgramClient,
      LemonGateway.Voice.CallSession,
      LemonGateway.AI
    ]

    for mod <- modules do
      case Code.ensure_compiled(mod) do
        {:module, _} ->
          # Force recompile and reload
          IEx.Helpers.recompile()
          IO.puts("✓ #{mod} reloaded")

        {:error, reason} ->
          IO.puts("✗ #{mod} failed: #{inspect(reason)}")
      end
    end

    IO.puts("\nReload complete. Try calling again!")
  end
end

VoiceReloader.reload()
