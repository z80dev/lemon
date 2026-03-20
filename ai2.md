Implement PR2 of the AI extraction.

Assume PR1 already landed and `apps/lemon_ai_runtime` exists with `LemonAiRuntime.Auth.*` façade delegates. If that prerequisite is missing, stop and report it instead of improvising.

Goal
Finish the external auth namespace cutover so no code outside `apps/ai` and `apps/lemon_ai_runtime` references `Ai.Auth.*`.

This PR is still façade-only:
- no auth logic moves
- no provider behavior changes
- no resolved-options API yet

Hard constraints
- Do not touch `apps/ai/**`
- Do not move or rewrite auth logic
- Do not add `LemonAiRuntime.Options`
- Do not touch `coding_agent`
- Do not refactor the lemon_sim examples beyond mechanical namespace swaps
- Keep diffs surgical
- Do not ask clarifying questions

Current remaining code hits to migrate
- `apps/lemon_sim/priv/scripts/check_providers.exs`
- `apps/lemon_sim/lib/lemon_sim/game_helpers/config.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/*.ex`
- `apps/lemon_sim/AGENTS.md`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex`

Make these changes:

1) Add `:lemon_ai_runtime` deps
- In `apps/lemon_sim/mix.exs`, add:
  `{:lemon_ai_runtime, in_umbrella: true}`
- In `apps/lemon_channels/mix.exs`, add:
  `{:lemon_ai_runtime, in_umbrella: true}`
- Do not add `:ai` to `lemon_channels`

2) Migrate all remaining `lemon_sim` callsites to `LemonAiRuntime.Auth.*`
Mechanical namespace swap only.

Replace:
- `Ai.Auth.OAuthSecretResolver` -> `LemonAiRuntime.Auth.OAuthSecretResolver`
- `Ai.Auth.OpenAICodexOAuth` -> `LemonAiRuntime.Auth.OpenAICodexOAuth`

Apply that to:
- `apps/lemon_sim/priv/scripts/check_providers.exs`
- `apps/lemon_sim/lib/lemon_sim/game_helpers/config.ex`
- every matching file under `apps/lemon_sim/lib/lemon_sim/examples/*.ex`
- `apps/lemon_sim/AGENTS.md`

Do not change control flow or resolution order in those files.

3) Fix `lemon_channels` transport to use the new boundary directly
In `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex`, replace the current dynamic probe for `Ai.Auth.OpenAICodexOAuth` / `get_api_key/0` with a direct call to `LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token/0`.

Use this exact implementation for `openai_codex_auth_available?/0`:

```elixir
defp openai_codex_auth_available? do
  case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token() do
    value when is_binary(value) -> String.trim(value) != ""
    _ -> false
  end
rescue
  _ -> false
end

No other behavior changes in transport.ex.
	4.	Update architecture policy
In apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex:

	•	add :lemon_ai_runtime as an allowed direct dep for :lemon_sim
	•	add :lemon_ai_runtime as an allowed direct dep for :lemon_channels

Preserve any PR1 changes that already added lemon_ai_runtime for coding_agent and the lemon_ai_runtime: [:ai] policy entry.
	5.	Add a guardrail rule so this regression cannot come back
In apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex, add one new rule that fails if any app outside apps/ai and apps/lemon_ai_runtime references Ai.Auth.*.

Use a rule equivalent to this:

%{
  code: :external_ai_auth_leak,
  message: "Apps outside ai/lemon_ai_runtime must use LemonAiRuntime.Auth.*, not Ai.Auth.*",
  files: [
    "apps/*/lib/**/*.ex",
    "apps/*/test/**/*.exs",
    "apps/*/priv/scripts/**/*.exs"
  ],
  exclude: [
    "apps/ai/**",
    "apps/lemon_ai_runtime/**"
  ],
  patterns: [
    "Ai.Auth.",
    "Elixir.Ai.Auth"
  ]
}

If a very similar rule already exists, extend it instead of duplicating it.
	6.	Docs
Keep docs minimal and truthful.

	•	Update apps/lemon_sim/AGENTS.md so it says LemonSim credential helpers should resolve OAuth-backed secrets through LemonAiRuntime.Auth.OAuthSecretResolver, not Ai.Auth.OAuthSecretResolver
	•	Refresh generated architecture docs via mix lemon.architecture.docs
	•	Do not do broad doc rewrites

Validation
Run and fix any issues caused by your changes:

mix format
mix compile
mix test apps/lemon_sim
mix test apps/lemon_channels
mix lemon.architecture.docs
mix lemon.quality

Run these grep checks:

rg -n 'Ai\.Auth\.|Elixir\.Ai\.Auth' apps \
  --glob '!apps/ai/**' \
  --glob '!apps/lemon_ai_runtime/**' \
  --glob '!**/*.md'

rg -n 'LemonAiRuntime\.Auth\.' apps/lemon_sim apps/lemon_channels

Expected results:
	•	first grep: no matches
	•	second grep: matches in lemon_sim source/script/docs and lemon_channels transport

Deliverable format
Report back with:
	1.	short summary of changed files
	2.	any deviations from this spec
	3.	grep outputs
	4.	validation commands run and whether they passed
	5.	any follow-up risks

Remember:
This PR is only the remaining caller cutover + guardrail.
Ownership boundary first. Implementation move later.
Behavior must stay the same.


