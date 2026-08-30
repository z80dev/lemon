# Self-hosted CI

Lemon has a repository-scoped Linux runner with the custom label `lemon-ci`.
It is an isolated Docker-in-Docker runner: workflows do not receive the host
Docker socket, production source trees, production volumes, or production
credentials.

## Which jobs use it

`.github/workflows/self-hosted-main.yml` calls the reusable Quality workflow on:

- pushes to `main`; and
- explicit maintainer `workflow_dispatch` runs.

The direct `pull_request` path in `quality.yml` remains on `ubuntu-latest`. Lemon
is public, so fork pull requests may contain arbitrary workflow and build code;
running that code on a self-hosted machine would be an avoidable host-security
risk. Other workflows that need macOS/Windows, publishing credentials, GitHub
Pages deployment, or live-model secrets remain on their existing hosted paths.

## Manual run

From an authenticated checkout:

```bash
gh workflow run self-hosted-main.yml --repo z80dev/lemon --ref main
gh run list --repo z80dev/lemon --workflow self-hosted-main.yml --limit 1
```

The final verification is a completed job whose runner is named
`lemon-ophy-ci-01`, not merely an online runner record.

## Adding trusted Linux work

For a reusable workflow that should be callable by the main-branch wrapper,
add a string `runner` input with `ubuntu-latest` as its default and use:

```yaml
runs-on: ${{ inputs.runner || 'ubuntu-latest' }}
```

Keep the direct pull-request trigger on the hosted default. Do not use this
runner for untrusted fork code, deployment credentials, wallet keys, or a host
Docker-socket mount.
