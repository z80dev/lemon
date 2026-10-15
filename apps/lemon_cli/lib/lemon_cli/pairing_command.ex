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

  def run(_args, _opts) do
    IO.puts(
      :stderr,
      "Usage: lemon pairing list | approve <telegram|discord> <CODE> | deny <telegram|discord> <CODE>"
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
        IO.puts(
          "Chat paired. Restart Lemon to apply the updated allowlist; project overrides still take precedence."
        )

        0

      {:error, _} ->
        failure(
          "Code consumed, but the gateway config could not be updated. Correct the config and ask the sender for a new request."
        )
    end
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
