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
      { text: "Install", link: "/install" },
      { text: "Compare", link: "/compare" },
      { text: "Demo", link: "/demo" },
      { text: "Launch Plan", link: "/plans/lemon-1.0-mainstream-readiness" },
      { text: "Support", link: "/support" },
      { text: "Architecture", link: "/architecture/overview" },
    ],

    sidebar: [
      {
        text: "Product",
        items: [
          { text: "Home", link: "/" },
          { text: "Install", link: "/install" },
          { text: "Compare", link: "/compare" },
          { text: "Demo", link: "/demo" },
          { text: "Support", link: "/support" },
        ],
      },
      {
        text: "Launch",
        items: [
          { text: "Lemon 1.0 Readiness", link: "/plans/lemon-1.0-mainstream-readiness" },
          { text: "Fresh Install Proof", link: "/plans/lemon-1.0-fresh-install-proof-2026-05-11" },
          { text: "Release Artifact Proof", link: "/plans/lemon-1.0-release-artifact-proof-2026-05-11" },
          { text: "Interface Supportability Audit", link: "/plans/lemon-1.0-interface-supportability-audit-2026-05-11" },
          { text: "Interface Proof Pack", link: "/plans/lemon-1.0-interface-proof-pack-2026-05-11" },
          { text: "Hermes Parity Scorecard", link: "/plans/lemon-hermes-agent-harness-parity-scorecard" },
        ],
      },
      {
        text: "User Guide",
        items: [
          { text: "Setup", link: "/user-guide/setup" },
          { text: "Skills", link: "/user-guide/skills" },
          { text: "Memory", link: "/user-guide/memory" },
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
          { text: "Testing", link: "/testing" },
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
}
