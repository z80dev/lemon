import { repositoryLinks } from './source-links.mjs'

// VitePress site configuration for Lemon documentation.
// Repo markdown files are the source of truth — this config only defines
// navigation structure. Do not duplicate content here.
// See docs/README.md for the canonical documentation hub.

export default {
  title: "Lemon",
  description: "Your agents. Your machine. Your move. Lemon is a local-first AI assistant and agent platform built on Elixir/OTP.",
  base: "/lemon/",
  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/lemon/brand/lemon-mark.svg" }],
    ["meta", { name: "theme-color", content: "#f6f5ed" }],
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:site_name", content: "Lemon" }],
  ],
  themeConfig: {
    logo: "/brand/lemon-mark.svg",
    nav: [
      { text: "Get started", link: "/getting-started/quickstart" },
      { text: "Docs", link: "/README" },
      { text: "Why Lemon", link: "/compare" },
      { text: "Build", items: [
        { text: "Your first agent", link: "/getting-started/build-your-first-agent" },
        { text: "Architecture", link: "/architecture/overview" },
        { text: "LemonSim & benchmarks", link: "/benchmarks/quickstart" },
      ] },
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
          { text: "Browser interface", link: "/user-guide/web" },
          { text: "Agent profiles", link: "/user-guide/profiles" },
          { text: "CLI & sessions", link: "/user-guide/cli" },
          { text: "Lemon in Tern", link: "/user-guide/tern" },
          { text: "Reminders & heartbeats", link: "/user-guide/reminders-and-heartbeats" },
          { text: "Learn from sources", link: "/user-guide/learn-from-sources" },
          { text: "Backup and Restore", link: "/user-guide/backups" },
          { text: "Skills", link: "/user-guide/skills" },
          { text: "Memory", link: "/user-guide/memory" },
          { text: "Honcho Memory", link: "/user-guide/honcho" },
          { text: "Delegating to omp", link: "/user-guide/omp" },
          { text: "Migrate from Hermes", link: "/user-guide/migrate-from-hermes" },
          { text: "Adaptive Features", link: "/user-guide/adaptive" },
          { text: "Feature Rollout", link: "/user-guide/rollout" },
        ],
      },
      {
        text: "Benchmarks",
        collapsed: true,
        items: [
          { text: "Quickstart", link: "/benchmarks/quickstart" },
          { text: "VendingBench", link: "/benchmarks/vending-bench" },
          { text: "Platform Guarantees", link: "/benchmarks/platform" },
          {
            text: "Platform Microbenchmarks",
            link: "/benchmarks/platform-microbenchmarks",
          },
          { text: "Run Your Own Model", link: "/benchmarks/run-your-model" },
        ],
      },
      {
        text: "Architecture",
        collapsed: true,
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
        collapsed: true,
        items: [
          { text: "Configuration", link: "/config" },
          { text: "Backup and Restore", link: "/user-guide/backups" },
          { text: "Testing", link: "/testing" },
          { text: "Extensions", link: "/extensions" },
          { text: "Versioning & Channels", link: "/release/versioning_and_channels" },
          { text: "Release Checklist", link: "/release/release_checklist_and_support_policy" },
        ],
      },
      {
        text: "Skills",
        collapsed: true,
        items: [
          { text: "Skills Overview", link: "/skills" },
          { text: "Manifest Reference", link: "/reference/skill-manifest-v2" },
        ],
      },
      {
        text: "Tools",
        collapsed: true,
        items: [
          { text: "Web", link: "/tools/web" },
          { text: "Firecrawl", link: "/tools/firecrawl" },
          { text: "Media", link: "/tools/media" },
          { text: "LSP", link: "/tools/lsp" },
          { text: "Debugger", link: "/tools/debug" },
          { text: "omp delegate", link: "/tools/omp" },
          { text: "OpenAI-Compatible API", link: "/tools/openai-compatible-api" },
          { text: "ACP", link: "/tools/acp" },
          { text: "WASM", link: "/tools/wasm" },
        ],
      },
      {
        text: "Contributing",
        collapsed: true,
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
    config: repositoryLinks,
  },
}
