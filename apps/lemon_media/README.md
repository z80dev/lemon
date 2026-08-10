# LemonMedia

Media job tracking for agents: what your agent generated, recorded without
recording anything you would not want on disk.

`lemon_media` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. Its only Lemon dependency is `lemon_core`.

## What is in it

| Module | Purpose |
|---|---|
| `LemonMedia.MediaJobs` | The job record store: `record/2`, `recent/1`, `summary/1`, `cleanup/1` |
| `LemonMedia.MediaJobSupervisor` | Dynamic supervisor for job workers, with `start_job/2` and `status/0` |
| `LemonMedia.MediaJobWorker` | Runs one job, recording `queued → running → completed`/`failed` as it goes |

`mix lemon.media` inspects jobs and artifacts from the command line.

## Installation

```elixir
def deps do
  [{:lemon_media, "~> 0.1"}]
end
```

## Recording a job

```elixir
LemonMedia.MediaJobs.record(
  %{type: :image, status: :completed, provider: "openai", prompt: "a lemon"},
  project_dir: File.cwd!()
)
```

Or let a supervised worker run it and record each transition:

```elixir
{:ok, _pid, job} =
  LemonMedia.MediaJobSupervisor.start_job(
    %{type: :video, provider: "runway"},
    runner: fn attrs -> {:ok, %{artifact: "/path/to/out.mp4"}} end
  )
```

Each lifecycle transition is broadcast on the `"media_jobs"` topic of
`LemonCore.PubSub` as `{:media_job, event, job}`.

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
