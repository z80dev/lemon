---
name: Bug report
about: Report a problem with Lemon
labels: bug
assignees: z80
---

## Describe the bug

A clear description of what happened and what you expected to happen.

## Steps to reproduce

1. ...
2. ...
3. ...

## Environment

- **Install type**: source-dev / release-runtime
- **Lemon version / commit**: source-dev: run `git log -1 --format="%H %s"`; release-runtime: include release artifact/version if available
- **Elixir version**: (run `elixir -v`)
- **Erlang/OTP version**: (run `erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell`)
- **OS**: (e.g. macOS 14.x, Arch Linux)
- **Engine**: native lemon / claude / codex / opencode / pi
- **Channel**: Telegram / TUI / Web / other

## Relevant logs or output

```
Paste any error messages, stack traces, or log output here.
```

## Doctor output

```
Paste the output of `mix lemon.doctor` here.
```

## Support bundle

For source-dev installs, attach the redacted zip from:

```bash
mix lemon.doctor --bundle
```

For release-runtime installs, attach the redacted zip from:

```bash
./bin/lemon_runtime_full eval 'LemonCore.Doctor.CLI.bundle!()'
```

Review the bundle before attaching it. Do not attach raw config files, provider keys, tokens, private prompts, memory contents, or tool outputs.

## Additional context

Any other context about the problem.
