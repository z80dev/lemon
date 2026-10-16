# Changelog

All notable changes to `lemon_new` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Generated agents consume ownership-bearing tool registration triples and fence
  unknown contributions before construction and execution with `build_tool/2`.

### Added

- `mix lemon.new --hex` generates a project that depends on the published
  `lemon_core`, `lemon_ai`, `lemon_agent` (and `lemon_memory` with `--memory`)
  packages as `~> 0.2` Hex requirements, so no checkout of the lemon repository
  is needed. It is refused with `--channel`, `--lemon-path` and
  `--packages-path`: `lemon_channels` is not published.
- An installer that was not built from a lemon checkout (one installed from Hex)
  generates the `--hex` form by default; `--channel` there asks for
  `--lemon-path`.
- Package metadata (description, MIT license, links, file list), so `lemon_new`
  can be published to Hex and installed with `mix archive.install hex lemon_new`.
