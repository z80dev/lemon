# LemonMedia

Media jobs for agents: the provider drivers that generate, transcribe and
analyze media, and a record of what your agent generated kept without
recording anything you would not want on disk.

`lemon_media` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. Its only Lemon dependency is `lemon_core`.

## What is in it

| Module | Purpose |
|---|---|
| `LemonMedia.MediaJobs` | The job record store: `record/2`, `recent/1`, `summary/1`, `cleanup/1` |
| `LemonMedia.MediaJobSupervisor` | Bounded task supervisor; `run_job/2` runs one job synchronously against a deadline, `status/0` reports activity |
| `LemonMedia.MediaJobWorker` | Job body that records `queued → running → completed`/`failed` |
| `LemonMedia.Providers` | `run/1`: the single entry point for finite media jobs (image, speech, video, vision, transcription) |
| `LemonMedia.Providers.Http` | The one retry/timeout/redacted-error helper the drivers share |
| `LemonMedia.Providers.SpeechStream` | Streaming OpenAI speech client used by channel voice replies |
| `LemonMedia.Providers.DeepgramStream` | Streaming STT for gateway calls; gateway owns the per-call socket lifecycle |
| `LemonMedia.GoogleAuth` | Google service-account access tokens, cached until shortly before expiry |
| `LemonMedia.Artifact` | Alias-safe artifact writes |

`mix lemon.media` inspects jobs and artifacts from the command line.

## Installation

`lemon_media` is an app in the Lemon umbrella, not a Hex package: it ships as part
of the reference runtime and is consumed in-repo by `lemon_router`,
`lemon_channels`, `lemon_gateway` and `lemon_skills`. See `docs/platform-split.md` for the
published package set.

## Recording a job

```elixir
LemonMedia.MediaJobs.record(
  %{type: :image, status: :completed, provider: "openai", prompt: "a lemon"},
  project_dir: File.cwd!()
)
```

Or run it under the job supervisor and wait for the outcome:

```elixir
{:ok, job} =
  LemonMedia.MediaJobSupervisor.run_job(
    %{type: :video, provider: "runway"},
    runner: fn attrs -> {:ok, %{artifact_path: "/path/to/out.mp4"}} end,
    timeout_ms: 600_000,
    aborted?: fn -> false end
  )
```

`run_job/2` waits against one monotonic deadline; unrelated mailbox messages
are neither consumed nor extend it. A job never outlives its caller: on
timeout (`{:error, {:cancelled, :timeout, job}}`), abort
(`{:error, {:cancelled, :aborted, job}}`) or caller exit the job process is
killed, which cancels any in-flight provider request, and the record ends
`:cancelled`. A job that crashes or is killed by someone else ends `:failed`
(`{:error, {:failed, job}}`); runner errors also end `:failed`. Jobs are never
restarted or retried.

Admission is bounded to 1024 concurrent jobs by default. Configure
`:lemon_core, :task_supervisor_max_children` with a map entry keyed by
`LemonMedia.MediaJobSupervisor` to change that cap. `run_job/2` returns
`{:error, :task_capacity_reached}` or `{:error, :task_supervisor_unavailable}`
without running the job when admission is rejected, after marking the queued
record failed.

Job types are `:media`, `:image`, `:video`, `:audio`, `:tts`, `:stt`, `:vision`
and `:browser`; statuses are `:queued`, `:running`, `:completed`, `:failed` and
`:cancelled`.

## What gets stored

Records are **redacted by construction**. Free text never lands on disk: a
prompt is stored as `prompt_hash` plus `prompt_chars`, an error as `error_hash`
plus a coarse `error_kind`, and provider, model, channel and artifact names go
through label redaction. That is the reason this is a separate store rather
than a log line.

## Paths and retention

Jobs default to `<project_dir>/.lemon/media-jobs` and artifacts to
`<project_dir>/.lemon/media-artifacts`; both are overridable per call with the
`:dir` and `:artifacts_dir` options, and `:project_dir` moves the pair.

`cleanup/1` prunes by age and count, defaulting to 30 days, 500 jobs and 250
artifacts. `summary/1` reports the current counts alongside the cleanup policy
in force.
