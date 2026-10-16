defmodule LemonCli.PairingCommand do
  @moduledoc "Local operator client for owner-approved channel pairing."

  alias LemonCli.Setup.Gateway.AllowlistConfig
  alias LemonCore.Config.Modular

  def run(args, opts \\ [])

  def run(["list"], opts) do
    case request(%{"action" => "list"}, opts) do
      {:ok, %{"requests" => requests}} ->
        Enum.each(requests, fn row ->
          IO.puts(
            "#{row["platform"]}\t#{row["masked_chat_id"]}\t#{row["display_name"]}\t#{div(row["age_ms"], 60_000)}m"
          )
        end)

        if requests == [], do: IO.puts("No pending pairing requests.")
        0

      _ ->
        failure(
          "Could not list pairing requests; check the local runtime and operator authentication."
        )
    end
  end

  def run([action, platform, code], opts)
      when action in ["approve", "deny"] and platform in ["telegram", "discord"] do
    case request(%{"action" => "consume", "platform" => platform, "pairing_code" => code}, opts) do
      {:ok, %{"request" => row}} ->
        finish(action, platform, row, opts)

      _ ->
        failure(
          "Pairing request not found, expired, already used, or local operator access unavailable."
        )
    end
  end

  def run(["revoke", platform, chat_id], opts) when platform in ["telegram", "discord"] do
    path = Keyword.get(opts, :config_path, Modular.global_path())

    case Integer.parse(chat_id) do
      {id, ""} when id > 0 ->
        config = AllowlistConfig.remove(platform, id, path)
        live = apply_live("revoke", platform, id, opts)
        finish_revoke(config, live)

      _ ->
        usage()
    end
  end

  def run(_args, _opts), do: usage()

  defp usage do
    IO.puts(
      :stderr,
      "Usage: lemon pairing list | approve <telegram|discord> <CODE> | deny <telegram|discord> <CODE> | revoke <telegram|discord> <CHAT_ID>"
    )

    2
  end

  defp finish("deny", _platform, _row, _opts) do
    IO.puts("Pairing request denied.")
    0
  end

  defp finish("approve", platform, row, opts) do
    path = Keyword.get(opts, :config_path, Modular.global_path())

    case AllowlistConfig.add(platform, row["chat_id"], path) do
      :ok ->
        finish_approve(apply_live("activate", platform, row["chat_id"], opts))

      {:error, _} ->
        failure(
          "Code consumed, but the gateway config could not be updated. Correct the config and ask the sender for a new request."
        )
    end
  end

  defp finish_approve({:ok, %{"live" => true}}) do
    IO.puts("Chat paired. The running gateway accepts its next message; no restart needed.")
    0
  end

  defp finish_approve({:ok, %{"live" => false}}) do
    IO.puts(
      "Chat paired. The channel is not running; the allowlist applies when it starts (project overrides still take precedence)."
    )

    0
  end

  defp finish_approve(_unavailable) do
    failure(
      "Chat saved to the gateway config, but the running gateway could not be updated. Restart Lemon to apply the allowlist; project overrides still take precedence."
    )
  end

  defp finish_revoke(config, live) do
    case {config, live} do
      {:ok, {:ok, %{"live" => true}}} ->
        IO.puts("Chat revoked. The running gateway rejects its next message.")
        0

      {:ok, {:ok, %{"live" => false}}} ->
        IO.puts("Chat revoked. The channel is not running; the removal applies when it starts.")
        0

      {:ok, _} ->
        failure(
          "Chat removed from the gateway config, but the running gateway could not be updated. Restart Lemon to revoke access."
        )

      {_, {:ok, _}} ->
        failure(
          "Chat revoked on the running gateway, but the gateway config could not be updated. Correct the config so the revocation survives a restart."
        )

      _ ->
        failure(
          "Could not revoke the chat; check the gateway config, the local runtime and operator authentication."
        )
    end
  end

  defp apply_live(action, platform, chat_id, opts) do
    request(
      %{"action" => action, "platform" => platform, "chat_id" => to_string(chat_id)},
      opts
    )
  end

  defp request(params, opts) do
    client = Keyword.get(opts, :client, LemonCli.ControlPlaneClient)
    client.request("channels.pairing", params)
  end

  defp failure(message) do
    IO.puts(:stderr, message)
    1
  end
end
