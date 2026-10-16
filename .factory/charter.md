- Run focused checks only: for Elixir, `mix format` on changed files and the
  narrowest relevant `scripts/test path …`; dependencies are already fetched and
  compiled in your workspace. Do not run full umbrella lanes.
- Under the factory, `scripts/test` BEAM lanes route through the heavy-check
  lease (`FACTORY_HEAVY_RUNNER`). Direct `mix` commands bypass it; prefer the
  routed lanes for anything that compiles or runs tests.
- User-visible changes need the affected app's CHANGELOG entry; keep both sides
  of any changelog conflict.
