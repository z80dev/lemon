defmodule LemonCli.LearningCommand do
  @moduledoc "Mix-free, read-only CLI adapter for LemonSkills.Timeline."

  alias LemonCli.Onboarding.LogSilencer

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, kind: :string, limit: :integer, json: :boolean]
      )

    limit = Keyword.get(opts, :limit, 50)
    kind = Keyword.get(opts, :kind, "all")
    profile = Keyword.get(opts, :profile, "default")

    if invalid != [] or rest != [] or limit not in 1..100 or
         kind not in ~w(all memory user project skill) or
         not Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, profile) do
      IO.puts(
        :stderr,
        "Usage: lemon learning [--profile ID] [--kind memory|user|project|skill] [--limit 1..100] [--json]"
      )

      2
    else
      execute(profile, kind, limit, opts[:json] == true)
    end
  end

  defp execute(profile, kind, limit, json?) do
    result =
      LogSilencer.with_quiet_logs(json?, fn ->
        with {:ok, _} <- Application.ensure_all_started(:lemon_skills) do
          service = Application.get_env(:lemon_cli, :timeline_service, LemonSkills.Timeline)
          service.for_profile(profile, kind: kind, limit: limit)
        end
      end)

    case result do
      {:ok, payload} ->
        output(payload, json?)
        0

      _ ->
        message =
          "Learning timeline unavailable. Check the local profile and memory/skill storage."

        if json?,
          do:
            IO.puts(
              :stderr,
              Jason.encode!(%{"error" => "timeline_unavailable", "message" => message})
            ),
          else: IO.puts(:stderr, message)

        1
    end
  end

  defp output(payload, true), do: IO.puts(Jason.encode!(payload))

  defp output(payload, false) do
    IO.puts("Learning timeline (newest first; current-state timestamps, not full history)")
    if payload["items"] == [], do: IO.puts("No learning events in the bounded source window.")

    Enum.each(payload["items"], fn item ->
      date =
        case DateTime.from_unix(item["at"], :millisecond) do
          {:ok, date} -> DateTime.to_iso8601(date)
          _ -> "Unknown date"
        end

      IO.puts("#{date}  #{item["kind"]}/#{item["action"]}  #{item["id"]}")
      IO.puts("  #{item["preview"]}")
    end)

    IO.puts("Manage memory IDs in Web → Memory; edit notes with remember(text, replaces).")
    IO.puts("Manage skill IDs with lemon skill / lemon skill draft (see --help).")
  end
end
