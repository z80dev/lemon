// VitePress site configuration for Lemon documentation.
// Repo markdown files are the source of truth — this config only defines
// navigation structure. Do not duplicate content here.
// See docs/README.md for the canonical documentation hub.

export default {
  title: "Lemon",
  description: "Lemon AI assistant platform — documentation",
  base: "/lemon/",
  themeConfig: {
    nav: [
      { text: "Home", link: "/" },
      { text: "Quickstart", link: "/getting-started/quickstart" },
      { text: "Install", link: "/install" },
      { text: "Compare", link: "/compare" },
      { text: "Demo", link: "/demo" },
      { text: "Support", link: "/support" },
      { text: "Architecture", link: "/architecture/overview" },
    ],

    sidebar: [
      {
        text: "Product",
        items: [
          { text: "Home", link: "/" },
          { text: "Quickstart", link: "/getting-started/quickstart" },
          { text: "Install", link: "/install" },
          { text: "Compare", link: "/compare" },
          { text: "Demo", link: "/demo" },
          { text: "Support", link: "/support" },
        ],
      },
      {
        text: "User Guide",
        items: [
          { text: "Setup", link: "/user-guide/setup" },
          { text: "Backup and Restore", link: "/user-guide/backups" },
          { text: "Skills", link: "/user-guide/skills" },
          { text: "Memory", link: "/user-guide/memory" },
          { text: "Honcho Memory", link: "/user-guide/honcho" },
          { text: "Migrate from Hermes", link: "/user-guide/migrate-from-hermes" },
          { text: "Adaptive Features", link: "/user-guide/adaptive" },
          { text: "Feature Rollout", link: "/user-guide/rollout" },
        ],
      },
      {
        text: "Architecture",
        items: [
          { text: "Overview", link: "/architecture/overview" },
          { text: "BEAM Agents", link: "/beam_agents" },
          { text: "App Boundaries", link: "/architecture_boundaries" },
          { text: "Review (Sep 2026)", link: "/architecture/review-2026-09" },
          { text: "Reliability Contracts", link: "/platform/reliability-contracts" },
          { text: "Model Selection", link: "/model-selection-decoupling" },
          { text: "Context Management", link: "/context" },
          { text: "Bootstrap Contract", link: "/assistant_bootstrap_contract" },
          { text: "Hot Reload", link: "/runtime-hot-reload" },
          { text: "Telemetry", link: "/telemetry" },
        ],
      },
      {
        text: "Operations",
        items: [
          { text: "Configuration", link: "/config" },
          { text: "Backup and Restore", link: "/user-guide/backups" },
          { text: "Testing", link: "/testing" },
          { text: "Platform Microbenchmarks", link: "/benchmarks/platform-microbenchmarks" },
          { text: "Extensions", link: "/extensions" },
          { text: "Versioning & Channels", link: "/release/versioning_and_channels" },
          { text: "Release Checklist", link: "/release/release_checklist_and_support_policy" },
        ],
      },
      {
        text: "Skills",
        items: [
          { text: "Skills Overview", link: "/skills" },
          { text: "Skills v2", link: "/skills_v2" },
        ],
      },
      {
        text: "Tools",
        items: [
          { text: "Web", link: "/tools/web" },
          { text: "Firecrawl", link: "/tools/firecrawl" },
          { text: "Execute Code", link: "/tools/execute-code" },
          { text: "Media", link: "/tools/media" },
          { text: "LSP", link: "/tools/lsp" },
          { text: "OpenAI-Compatible API", link: "/tools/openai-compatible-api" },
          { text: "ACP", link: "/tools/acp" },
          { text: "WASM", link: "/tools/wasm" },
        ],
      },
      {
        text: "For Non-Elixir Users",
        link: "/for-dummies/README",
        items: [
          { text: "Big Picture", link: "/for-dummies/01-big-picture" },
          { text: "Message Journey", link: "/for-dummies/02-message-journey" },
          { text: "Front Door", link: "/for-dummies/03-the-front-door" },
          { text: "Traffic Cop", link: "/for-dummies/04-the-traffic-cop" },
          { text: "Engine Room", link: "/for-dummies/05-the-engine-room" },
          { text: "The Agent", link: "/for-dummies/06-the-agent" },
          { text: "Talking to LLMs", link: "/for-dummies/07-talking-to-llms" },
          { text: "Foundation", link: "/for-dummies/08-the-foundation" },
        ],
      },
      {
        text: "Contributing",
        items: [
          { text: "Safety", link: "/security/safety" },
          { text: "Security", link: "/security/secrets-migration-guide" },
          { text: "Public Repo Basics", link: "/contributor/public_repo_basics" },
        ],
      },
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/z80dev/lemon" },
    ],

    footer: {
      message: "Released under the MIT License.",
      copyright: "Copyright 2024-2026 z80",
    },

    search: {
      provider: "local",
    },

    editLink: {
      pattern: "https://github.com/z80dev/lemon/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },
  },

  markdown: {
    // Allow mermaid diagrams if included in docs
    // theme: { light: "github-light", dark: "github-dark" },
  },

  // Links into the umbrella source tree (e.g. ../apps/lemon_core/lib/lemon_core/env.ex)
  // are intentional references to real files, but VitePress treats unknown
  // extensions as HTML pages and flags them as dead links.
  //
  // These links are not unchecked: LemonCore.Quality.DocsCheck (run by
  // `mix lemon.quality`) resolves every local markdown link against the
  // filesystem, which is the correct check for a path outside the site root.
  ignoreDeadLinks: [/(^|\/)\.\.\/(apps|clients|bin)\//],
}
