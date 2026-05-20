defmodule Mix.Tasks.Lemon.Channels do
  @moduledoc """
  Show redacted Telegram and Discord launch readiness.

  ## Usage

      mix lemon.channels
      mix lemon.channels --project-dir /path/to/project
      mix lemon.channels --json

  ## Options

    * `--project-dir` - Project root to scan. Defaults to the current directory.
    * `--json` - Emit the raw redacted readiness JSON.
  """

  use Mix.Task

  alias LemonCore.Doctor.ChannelReadiness

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project_dir: :string,
          json: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    project_dir = opts[:project_dir] || File.cwd!()
    status = ChannelReadiness.status(project_dir: project_dir)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print_text(status)
    end
  end

  defp print_text(status) do
    cleanup = Map.get(status, :cleanup, %{})

    Mix.shell().info("Lemon Channels")
    Mix.shell().info("Status: #{Map.get(status, :status, "unknown")}")

    Mix.shell().info(
      "Promoted platforms: #{Enum.join(Map.get(status, :promoted_platforms, []), ", ")}"
    )

    Mix.shell().info("Gates: #{Map.get(status, :gate_count, 0)}")
    Mix.shell().info("Passed: #{Map.get(status, :passed_count, 0)}")
    Mix.shell().info("Blocked: #{Map.get(status, :blocked_count, 0)}")
    Mix.shell().info("Warnings: #{Map.get(status, :warning_count, 0)}")
    Mix.shell().info("Skipped: #{Map.get(status, :skipped_count, 0)}")
    Mix.shell().info("Includes raw bot tokens: #{truthy?(cleanup[:includes_raw_bot_tokens])}")
    Mix.shell().info("Includes secret names: #{truthy?(cleanup[:includes_secret_names])}")
    Mix.shell().info("Includes chat IDs: #{truthy?(cleanup[:includes_chat_ids])}")
    Mix.shell().info("Includes channel IDs: #{truthy?(cleanup[:includes_channel_ids])}")
    Mix.shell().info("Includes message bodies: #{truthy?(cleanup[:includes_message_bodies])}")
    Mix.shell().info("Includes raw proof paths: #{truthy?(cleanup[:includes_raw_proof_paths])}")

    Mix.shell().info(
      "Includes raw proof details: #{truthy?(cleanup[:includes_raw_proof_details])}"
    )

    Mix.shell().info("")
    Mix.shell().info("Launch Gates:")

    status
    |> Map.get(:gates, [])
    |> Enum.each(fn gate ->
      reason = if gate[:reason_kind], do: " reason=#{gate.reason_kind}", else: ""
      next_action = if gate[:next_action], do: " next=#{gate.next_action}", else: ""

      Mix.shell().info(
        "  #{gate.id}: #{gate.status} evidence=#{gate.evidence}#{reason}#{next_action}"
      )
    end)
  end

  defp truthy?(value), do: if(value, do: "true", else: "false")
end
