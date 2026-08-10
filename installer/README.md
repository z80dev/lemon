# lemon_new

`mix lemon.new` — the project generator for the Lemon agent platform.

This is a standalone Mix project, not an umbrella app. It is built and
installed as a Mix archive, which is why it has no dependencies: an archive
cannot carry any. The templates under `templates/` are read at compile time and
embedded in the generated beam files.

## Install it

    cd installer
    MIX_ENV=prod mix archive.build
    mix archive.install lemon_new-0.1.0.ez

## Use it

    mix lemon.new my_agent
    cd my_agent
    mix test

The generated project depends on the platform packages by path, because they
are not published to Hex yet. The path is baked in from the checkout the
archive was built from; override it with `--lemon-path` or `$LEMON_PATH`.

Run `mix help lemon.new` for the full option list.

## Work on it

    cd installer
    mix test

The suite generates projects into a temporary directory and asserts on their
contents. It does not compile them — that would mean fetching the platform's
whole dependency tree per test. The generated project is compiled and its tests
are run as part of the repository's release checks; see
`docs/getting-started/build-your-first-agent.md`.

## Adding a template

1. Put the `.eex` file under `templates/base`, `templates/channel` or
   `templates/memory`.
2. Add a `{template, destination}` pair to the matching list in
   `LemonNew.Generator`. Destinations may contain `:app`, which is replaced with
   the application name.

Generated `.ex` and `.exs` files are run through `Code.format_string!/1`, so a
template that no longer parses fails generation instead of producing a broken
project.
