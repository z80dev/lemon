# Run Your Own Model

Offline strategies are useful for smoke tests. To rank real models, run
VendingBench with `--model` and, optionally, a separate `--worker-model`.

## Model Resolution

Model ids resolve through the `ai` app's `Ai.Models` registry. The current
source has 27 providers in `Ai.Models.get_providers/0`.

Use either:

```text
provider:model-id
```

or a bare model id when it is unique enough for `Ai.Models.find_by_id/1`.

For a live run, replace the quickstart's `--offline-strategy baseline` with
`--model provider:model-id`. Add `--worker-model provider:model-id` when the
physical worker should use a different model from the operator.

`--model` controls the operator. `--worker-model` controls the physical-worker
subagent. If `--worker-model` is omitted, the worker uses the operator model.

## Credentials

VendingBench loads Lemon config, resolves the model, applies any provider
`base_url`, then resolves credentials for the model provider.

Credential lookup checks:

- `providers.<provider>.api_key` in Lemon config
- `providers.<provider>.api_key_secret`, resolved through Lemon secrets with env fallback
- default secret name `llm_<provider>_api_key`, also with env fallback
- provider-specific OAuth paths for providers such as `openai-codex`

Common environment variables include:

| Provider family | Common env vars |
| --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| OpenAI Codex OAuth/API surfaces | `OPENAI_CODEX_API_KEY`, `CHATGPT_TOKEN` |
| Google AI Studio | `GOOGLE_GENERATIVE_AI_API_KEY`, `GOOGLE_API_KEY` |
| Google Gemini CLI | `GOOGLE_GEMINI_CLI_API_KEY` |
| Google Vertex | `GOOGLE_APPLICATION_CREDENTIALS_JSON`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` |
| Azure OpenAI | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_BASE_URL`, `AZURE_OPENAI_RESOURCE_NAME`, `AZURE_OPENAI_API_VERSION` |
| OpenAI-compatible providers | `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`, `FIREWORKS_API_KEY` |

Use [Configuration](../config.md) for the full provider configuration reference.

## Presets And Turn Counts

| Preset | Simulated days | Driver turn limit |
| --- | ---: | ---: |
| `ci` | 7 | 25 |
| `paper` | 365 | 2,000 |
| `v2` | 365 | 4,000 |

You can override with `--max-days` or `--max-turns` when you need a custom
budget. Long live runs can spend real money; start with `ci`.

## Resume From A Checkpoint

Live VendingBench supports checkpoint resume with `--resume-artifact-dir
path/to/artifact-dir`. The resumed run reuses that artifact directory as its
checkpoint source and resolves model credentials the same way as a fresh run.

## Rank Live Competitors

Suites accept repeated `--model provider:model-id` competitors alongside
offline competitors such as `--offline baseline`.

Each run is verified before it is ranked. The suite leaderboard reports the
primary metric, per-seed values, token totals, and cost totals. If a provider's
price metadata is unknown, the cost column stays unknown rather than being
reported as zero.

After multiple suites, aggregate them with the ratings task. Ratings compare
competitors on common seeds inside each suite and fit a Bradley-Terry
leaderboard across all supplied suites.
