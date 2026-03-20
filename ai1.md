Paste this to the code agent as-is:

Implement the first extraction slice for AI exactly as described below.

Goal
Create a new umbrella app `apps/lemon_ai_runtime` as a façade-only Lemon-owned boundary for AI auth/runtime concerns, and migrate only `coding_agent` to use it for OAuth secret resolution.

This PR is intentionally small. It must change ownership boundaries without moving real logic yet.

Success criteria
- `apps/lemon_ai_runtime` exists
- it contains thin `LemonAiRuntime.Auth.*` delegate modules
- `coding_agent` depends on `:lemon_ai_runtime`
- `coding_agent` no longer references `Ai.Auth.*`
- behavior is unchanged
- architecture policy/docs are updated
- docs are updated truthfully

Hard constraints
- Do not move any implementation out of `apps/ai`
- Do not change any auth behavior
- Do not touch provider behavior
- Do not add `LemonAiRuntime.Options`
- Do not touch `lemon_sim` or `lemon_channels`
- Do not remove `:lemon_core` from `apps/ai`
- Do not add compatibility delegates inside `apps/ai`
- Keep this PR small and boring
- Do not ask clarifying questions; make the smallest safe change set that satisfies this spec

Files to read first
- apps/coding_agent/lib/coding_agent/session/model_resolver.ex
- apps/coding_agent/test/coding_agent/session_api_key_resolution_test.exs
- apps/coding_agent/mix.exs
- apps/ai/lib/ai/auth/oauth_secret_resolver.ex
- apps/ai/lib/ai/auth/github_copilot_oauth.ex
- apps/ai/lib/ai/auth/google_antigravity_oauth.ex
- apps/ai/lib/ai/auth/google_gemini_cli_oauth.ex
- apps/ai/lib/ai/auth/openai_codex_oauth.ex
- apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex
- apps/lemon_core/lib/lemon_core/quality/architecture_check.ex
- root AGENTS.md
- apps/coding_agent/README.md
- apps/coding_agent/AGENTS.md
- apps/ai/README.md
- apps/ai/AGENTS.md
- docs/plans/2026-03-19-ai-boundary-extraction-plan.md

1) Create new umbrella app: apps/lemon_ai_runtime

Create this tree:

apps/lemon_ai_runtime/
  .formatter.exs
  AGENTS.md
  README.md
  mix.exs
  lib/lemon_ai_runtime.ex
  lib/lemon_ai_runtime/auth/oauth_secret_resolver.ex
  lib/lemon_ai_runtime/auth/github_copilot_oauth.ex
  lib/lemon_ai_runtime/auth/google_antigravity_oauth.ex
  lib/lemon_ai_runtime/auth/google_gemini_cli_oauth.ex
  lib/lemon_ai_runtime/auth/openai_codex_oauth.ex
  test/test_helper.exs

Do not add an Application module or supervision tree.

Use this mix file:

```elixir
defmodule LemonAiRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_ai_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ai, in_umbrella: true}
    ]
  end
end

Use this formatter config:

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]

Use this root module:

defmodule LemonAiRuntime do
  @moduledoc """
  Lemon-owned AI runtime boundary.

  In the first extraction slice this app is intentionally façade-only:
  `LemonAiRuntime.Auth.*` delegates to the current `Ai.Auth.*` implementation
  so Lemon apps can stop depending on `Ai.Auth.*` directly before the real
  implementation moves out of `apps/ai`.
  """
end

	2.	Add thin delegate modules under LemonAiRuntime.Auth

These modules must contain no logic besides defdelegate.

Create apps/lemon_ai_runtime/lib/lemon_ai_runtime/auth/oauth_secret_resolver.ex:

defmodule LemonAiRuntime.Auth.OAuthSecretResolver do
  @moduledoc """
  Lemon-side façade for OAuth secret resolution during AI extraction.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.OAuthSecretResolver
end

Create apps/lemon_ai_runtime/lib/lemon_ai_runtime/auth/github_copilot_oauth.ex:

defmodule LemonAiRuntime.Auth.GitHubCopilotOAuth do
  @moduledoc """
  Lemon-side façade for GitHub Copilot OAuth secret resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.GitHubCopilotOAuth
end

Create apps/lemon_ai_runtime/lib/lemon_ai_runtime/auth/google_antigravity_oauth.ex:

defmodule LemonAiRuntime.Auth.GoogleAntigravityOAuth do
  @moduledoc """
  Lemon-side façade for Google Antigravity OAuth secret resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.GoogleAntigravityOAuth
end

Create apps/lemon_ai_runtime/lib/lemon_ai_runtime/auth/google_gemini_cli_oauth.ex:

defmodule LemonAiRuntime.Auth.GoogleGeminiCliOAuth do
  @moduledoc """
  Lemon-side façade for Google Gemini CLI OAuth secret resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.GoogleGeminiCliOAuth
end

Create apps/lemon_ai_runtime/lib/lemon_ai_runtime/auth/openai_codex_oauth.ex:

defmodule LemonAiRuntime.Auth.OpenAICodexOAuth do
  @moduledoc """
  Lemon-side façade for OpenAI Codex OAuth resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.OpenAICodexOAuth

  @spec resolve_access_token() :: String.t() | nil
  defdelegate resolve_access_token(), to: Ai.Auth.OpenAICodexOAuth
end

Do not add OAuthPKCE or login-flow helpers in this PR.
	3.	Update architecture policy and namespace ownership

Update apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex.

Add:
	•	lemon_ai_runtime: [:ai]
	•	:lemon_ai_runtime to coding_agent allowed deps

The relevant map entries should end up equivalent to:

@allowed_direct_deps %{
  agent_core: [:ai, :lemon_core],
  ai: [:lemon_core],
  coding_agent: [:agent_core, :ai, :lemon_ai_runtime, :lemon_core, :lemon_skills],
  ...
  lemon_ai_runtime: [:ai],
  ...
}

Update apps/lemon_core/lib/lemon_core/quality/architecture_check.ex.

Add the namespace owner:

@app_namespaces %{
  ...
  lemon_ai_runtime: ["LemonAiRuntime"],
  ...
}

Only add exactly what is needed.

Afterward run:
mix lemon.architecture.docs

This should refresh generated architecture docs such as docs/architecture_boundaries.md. Do not manually rewrite generated content.
	4.	Migrate coding_agent only

Update apps/coding_agent/mix.exs.

Add:

{:lemon_ai_runtime, in_umbrella: true}

Keep :ai as a direct dependency.

Update apps/coding_agent/lib/coding_agent/session/model_resolver.ex.

Replace all Ai.Auth.* references with LemonAiRuntime.Auth.*.

Make these exact conceptual changes:

A. Replace the direct Codex resolver call:

Ai.Auth.OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, value)

becomes

LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, value)

B. Replace the fallback resolver list:

@oauth_secret_fallback_resolvers [
  Ai.Auth.GitHubCopilotOAuth,
  Ai.Auth.GoogleAntigravityOAuth,
  Ai.Auth.GoogleGeminiCliOAuth,
  Ai.Auth.OpenAICodexOAuth
]

becomes

@oauth_secret_fallback_resolvers [
  LemonAiRuntime.Auth.GitHubCopilotOAuth,
  LemonAiRuntime.Auth.GoogleAntigravityOAuth,
  LemonAiRuntime.Auth.GoogleGeminiCliOAuth,
  LemonAiRuntime.Auth.OpenAICodexOAuth
]

C. Replace the default dispatcher module:

defp oauth_secret_resolver_module do
  Application.get_env(:coding_agent, :oauth_secret_resolver_module, Ai.Auth.OAuthSecretResolver)
end

becomes

defp oauth_secret_resolver_module do
  Application.get_env(
    :coding_agent,
    :oauth_secret_resolver_module,
    LemonAiRuntime.Auth.OAuthSecretResolver
  )
end

Do not change resolution order or behavior.

Update apps/coding_agent/test/coding_agent/session_api_key_resolution_test.exs.

If there is a test that uses a fake missing module under Ai.Auth.*, rename it to a missing module under LemonAiRuntime.Auth.*, for example:

LemonAiRuntime.Auth.MissingOAuthSecretResolver

No real module should be created for that missing-module test.
	5.	Documentation updates

Keep docs small and accurate.

Create apps/lemon_ai_runtime/README.md with:
	•	this app is the Lemon-owned boundary for auth/config/runtime concerns around Ai
	•	this first slice is façade-only
	•	LemonAiRuntime.Auth.* currently delegates to Ai.Auth.*
	•	external Lemon apps should depend on LemonAiRuntime.Auth.*, not add new Ai.Auth.* references
	•	later slices will move real implementation here

Create apps/lemon_ai_runtime/AGENTS.md with explicit rules:
	•	current scope is façade-only
	•	do not move provider logic here yet
	•	do not add Options.resolve/3 yet
	•	no external app should add new direct Ai.Auth.* usage
	•	future work will move secret/config/OAuth ownership here incrementally

Update root AGENTS.md:
	•	add lemon_ai_runtime to the quick navigation / project structure areas
	•	describe it as the Lemon-side AI runtime/auth boundary

Update apps/coding_agent/README.md:
	•	wherever model resolution docs mention Ai.Auth.OAuthSecretResolver, change it to LemonAiRuntime.Auth.OAuthSecretResolver

Update apps/coding_agent/AGENTS.md:
	•	same replacement
	•	if a sentence claims Anthropic is one of the central OAuth payload decoders, verify it first; if untrue, remove Anthropic from that sentence

Update apps/ai/README.md:
	•	add a small truthful note that auth modules still live in apps/ai during extraction
	•	external Lemon apps should prefer LemonAiRuntime.Auth.* over adding new Ai.Auth.* references

Update apps/ai/AGENTS.md with the same guidance.

Optionally update docs/plans/2026-03-19-ai-boundary-extraction-plan.md with a short note that the first implementation slice is:
	•	create apps/lemon_ai_runtime as a façade-only auth boundary
	•	migrate coding_agent first
	•	leave real implementation in apps/ai for now

	6.	Non-goals: do not change these
Do not modify runtime/provider behavior in:

	•	apps/ai/lib/ai/providers/openai_codex_responses.ex
	•	apps/ai/lib/ai/auth/*
	•	apps/lemon_sim/**
	•	apps/lemon_channels/**

Do not add:
	•	LemonAiRuntime.Options
	•	LemonAiRuntime.Diagnostics
	•	LemonAiRuntime.Auth.OAuthPKCE

	7.	Validation

Run these commands and fix any issues caused by your changes:

mix format
mix compile
mix test apps/coding_agent/test/coding_agent/session_api_key_resolution_test.exs
mix lemon.architecture.docs
mix lemon.quality

If you add any real tests under apps/lemon_ai_runtime/test, also run:

mix test apps/lemon_ai_runtime

Also run these checks:

rg -n 'Ai\.Auth\.' apps/coding_agent
rg -n 'LemonAiRuntime\.Auth\.' apps/coding_agent

Expected:
	•	first command returns no matches
	•	second command returns matches in coding_agent source/docs/tests

	8.	Final deliverable format

When done, report back with:
	1.	a short summary of what changed
	2.	any deviations from the spec
	3.	the output of the grep checks
	4.	the validation commands you ran and whether they passed
	5.	any follow-up risks or next steps

Remember:
This is a façade-only ownership move.
Ownership moves first.
Implementation location moves later.
Behavior must remain unchanged.

The tighter variant, if you want the agent even more constrained, is to add this at the top:

```text
Make only the minimum file edits required to satisfy this spec. Prefer surgical diffs over refactors.
```
