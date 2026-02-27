# Setup script: registers the Games Platform cron job in LemonAutomation.
#
# Usage (with Lemon running):
#   mix run scripts/setup_games_cron_job.exs
#
# Or from iex:
#   Code.eval_file("scripts/setup_games_cron_job.exs")
#
# The job runs every hour, sending a focused prompt to the agent to iteratively
# finish, test, and deploy the games platform on zeebot.xyz.

alias LemonAutomation.CronManager

prompt = """
You are working on finishing the Lemon Games Platform — an agent-vs-agent turn-based
game platform in this Elixir umbrella app.

## Mission

Get the games platform to the finish line: fully developed, heavily tested, and deployed
at games.zeebot.xyz. Each run you should make meaningful, focused progress. One task per run.

## Key Files

- Design plan: planning/plans/PLN-20260226-agent-games-platform.md
- Implementation guide: planning/plans/PLN-20260226-agent-games-platform-implementation-guide.md
- Game engines: apps/lemon_games/lib/lemon_games/games/ (RPS, Connect4)
- Match service: apps/lemon_games/lib/lemon_games/matches/service.ex
- HTTP API: apps/lemon_control_plane/lib/lemon_control_plane/http/games_api.ex
- LiveView: apps/lemon_web/lib/lemon_web/live/games_lobby_live.ex, game_match_live.ex
- Bot workers: apps/lemon_games/lib/lemon_games/bot/
- Auth: apps/lemon_games/lib/lemon_games/auth.ex
- Builtin skill: apps/lemon_skills/priv/builtin_skills/agent-games/SKILL.md
- Docs: docs/games-platform.md

## Definition of Done (ALL must be true)

1. POST /v1/games/matches through POST /moves flow works for RPS and Connect4
2. Bot opponent fully plays matches to terminal state
3. /games and /games/:id update live during matches
4. Event replay reconstructs final state exactly
5. Admin can issue/list/revoke game tokens via control-plane RPC
6. Builtin skill can drive a full game loop
7. All docs updated
8. `mix format && mix compile && mix test && mix lemon.quality` pass with zero failures
9. Platform deployed and accessible at games.zeebot.xyz

## Deployment (when code is done)

- Fly.io deployment (reference: openclaw fly.toml pattern, zeebot-public Dockerfile)
- Release includes lemon_web + lemon_control_plane + lemon_games
- DNS: CNAME games.zeebot.xyz -> Fly app (Cloudflare DNS)
- Env: PHX_SERVER=1, LEMON_WEB_PORT=8080, SECRET_KEY_BASE

## Instructions

1. Run `mix test apps/lemon_games apps/lemon_control_plane apps/lemon_web` to assess state
2. If failures exist, fix them first
3. If tests pass, pick the highest-priority remaining gap vs Definition of Done
4. Implement ONE focused task
5. Run `mix format` and re-run tests
6. If items 1-8 are done, start deployment
7. Use your memory notes to track what was done and what's next

Always end your output with:

## Status: [x/9 DoD items complete]
## This Run: [what you did]
## Next Priority: [what next run should tackle]
"""

job_params = %{
  name: "games-platform-finish",
  schedule: "0 * * * *",
  agent_id: "my-agent",
  session_key: "agent:my-agent:main",
  prompt: prompt,
  enabled: true,
  timezone: "UTC",
  jitter_sec: 30,
  timeout_ms: 1_500_000,
  memory_file: Path.expand("~/.lemon/cron_memory/games_platform_finish.md"),
  meta: %{
    "purpose" => "finish_games_platform",
    "target" => "games.zeebot.xyz",
    "dod_items" => 9
  }
}

# Check if a games-platform-finish job already exists
existing =
  CronManager.list()
  |> Enum.find(&(Map.get(&1, :name) == "games-platform-finish"))

case existing do
  nil ->
    case CronManager.add(job_params) do
      {:ok, job} ->
        IO.puts("Cron job registered!")
        IO.puts("  ID:       #{job.id}")
        IO.puts("  Name:     #{job.name}")
        IO.puts("  Schedule: #{job.schedule} (every hour)")
        IO.puts("  Agent:    #{job.agent_id}")
        IO.puts("  Session:  #{job.session_key}")
        IO.puts("  Timeout:  #{job.timeout_ms}ms (25 min)")
        IO.puts("  Memory:   #{job.memory_file}")
        IO.puts("")
        IO.puts("The job will fire on the next hour. To run immediately:")
        IO.puts("  LemonAutomation.run_now(\"#{job.id}\")")

      {:error, reason} ->
        IO.puts("Failed to register cron job: #{inspect(reason)}")
        System.halt(1)
    end

  job ->
    IO.puts("Job 'games-platform-finish' already exists (#{job.id})")
    IO.puts("To update the prompt, use:")
    IO.puts("  LemonAutomation.update_job(\"#{job.id}\", %{prompt: new_prompt})")
    IO.puts("To trigger a run now:")
    IO.puts("  LemonAutomation.run_now(\"#{job.id}\")")
end
