defmodule LemonCli.Setup.Gateway.AllowlistConfig do
  @moduledoc "Shared canonical gateway allowlist patching for setup and owner pairing."

  alias LemonCore.Config.{Modular, TomlPatch}

  @doc "Replace a platform allowlist in TOML, preserving unrelated content."
  def patch(content, platform, ids) when platform in ["telegram", "discord"] do
    key = key(platform)

    TomlPatch.upsert_raw_line(
      content,
      "gateway.#{platform}",
      key,
      "#{key} = [#{Enum.join(ids, ", ")}]"
    )
  end

  @doc "Append a chat to the user config with serialized, atomic replacement."
  def add(platform, chat_id, path \\ Modular.global_path())
      when platform in ["telegram", "discord"] do
    path = Path.expand(path)
    :global.trans({{__MODULE__, path}, self()}, fn -> add_locked(platform, chat_id, path) end)
  end

  defp add_locked(platform, chat_id, path) do
    with {id, ""} <- Integer.parse(to_string(chat_id)),
         {:ok, content} <- read(path),
         {:ok, config} <- Toml.decode(content),
         ids when is_list(ids) <- get_in(config, ["gateway", platform, key(platform)]) || [],
         true <- Enum.all?(ids, &is_integer/1) do
      content = patch(content, platform, Enum.uniq(ids ++ [id]))
      write_atomic(path, content)
    else
      _ -> {:error, :config_write_failed}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, ""}
      result -> result
    end
  end

  defp write_atomic(path, content) do
    temp = path <> ".pairing-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, content, [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, path) do
        :ok
      else
        _ -> {:error, :config_write_failed}
      end
    after
      File.rm(temp)
    end
  end

  defp key("telegram"), do: "allowed_chat_ids"
  defp key("discord"), do: "allowed_channel_ids"
end
