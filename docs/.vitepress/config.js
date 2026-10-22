import { repositoryLinks } from './source-links.mjs'

// VitePress site configuration for Lemon documentation.
// Repo markdown files are the source of truth — this config only defines
// navigation structure. Do not duplicate content here.
// See docs/README.md for the canonical documentation hub.

export default {
  title: "Lemon",
  description: "Your agents. Your machine. Your move. Lemon is a local-first AI assistant and agent platform built on Elixir/OTP.",
  base: "/",
  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/brand/lemon-mark.svg" }],
    ["meta", { name: "theme-color", content: "#f6f5ed" }],
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:site_name", content: "Lemon" }],
  ],
  themeConfig: {
    logo: "/brand/lemon-mark.svg",
    nav: [
      { text: "Get started", link: "/getting-started/quickstart", activeMatch: "^/(getting-started/quickstart|install|demo|compare|support|why-beam-for-agents|user-guide/(setup|updates))" },
      { text: "User guides", link: "/user-guide/web", activeMatch: "^/(user-guide/(?!setup|updates|cli|tui-commands|tern|omp|a2a-peers|honcho)|tools/|security/)" },
      { text: "Reference", items: [
        { text: "Configuration", link: "/config" },
        { text: "Configuration registry", link: "/config-registry" },
        { text: "CLI & sessions", link: "/user-guide/cli" },
        { text: "TUI slash commands", link: "/user-guide/tui-commands" },
        { text: "Control-plane methods", link: "/reference/control-plane" },
        { text: "Skill manifest", link: "/reference/skill-manifest-v2" },
        { text: "Versioning & channels", link: "/release/versioning_and_channels" },
      ] },
      { text: "Integrations", items: [
        { text: "Add a channel", link: "/getting-started/add-a-channel" },
        { text: "Gateway (Telegram, Discord)", link: "/platform/lemon_gateway" },
        { text: "OpenAI-compatible API", link: "/tools/openai-compatible-api" },
        { text: "ACP editors", link: "/tools/acp" },
        { text: "Extensions & MCP", link: "/extensions" },
        { text: "Delegating to omp", link: "/user-guide/omp" },
      ] },
      { text: "Developers", items: [
        { text: "Build your first agent", link: "/getting-started/build-your-first-agent" },
        { text: "Architecture", link: "/architecture/overview" },
        { text: "Testing", link: "/testing" },
        { text: "Contributing", link: "/contributor/public_repo_basics" },
        { text: "LemonSim & benchmarks", link: "/benchmarks/quickstart" },
        { text: "Releases & packages", link: "/platform-split" },
      ] },
      { text: "All docs", link: "/README" },
    ],

    sidebar: [
      {
        text: "Getting started",
        items: [
          { text: "Home", link: "/" },
          { text: "Quickstart", link: "/getting-started/quickstart" },
          { text: "Install", link: "/install" },
          { text: "Setup: providers & secrets", link: "/user-guide/setup" },
          { text: "Demo", link: "/demo" },
          { text: "Update and roll back", link: "/user-guide/updates" },
          { text: "Capabilities & boundaries", link: "/compare" },
          { text: "Why BEAM for agents", link: "/why-beam-for-agents" },
          { text: "Support & troubleshooting", link: "/support" },
        ],
      },
      {
        text: "User guides",
        collapsed: true,
        items: [
          {
            text: "Everyday use",
            collapsed: true,
            items: [
              { text: "Browser interface", link: "/user-guide/web" },
              { text: "Agent profiles", link: "/user-guide/profiles" },
              { text: "Instruction files & rules", link: "/user-guide/context-files" },
              { text: "File slash commands", link: "/user-guide/slash-commands" },
              { text: "Context references", link: "/user-guide/context-references" },
            ],
          },
          {
            text: "Memory & learning",
            collapsed: true,
            items: [
              { text: "Memory", link: "/user-guide/memory" },
              { text: "Skills", link: "/user-guide/skills" },
              { text: "Learn from sources", link: "/user-guide/learn-from-sources" },
              { text: "Adaptive features", link: "/user-guide/adaptive" },
              { text: "Feature rollout", link: "/user-guide/rollout" },
            ],
          },
          {
            text: "Automation & nodes",
            collapsed: true,
            items: [
              { text: "Reminders & heartbeats", link: "/user-guide/reminders-and-heartbeats" },
              { text: "Attaching a bot machine", link: "/user-guide/attaching-a-bot-machine" },
              { text: "Phone & provider acceptance", link: "/user-guide/phone-acceptance" },
              { text: "Node files, secrets & processes", link: "/user-guide/node-files-and-secrets" },
            ],
          },
          {
            text: "Data & migration",
            collapsed: true,
            items: [
              { text: "Backup and restore", link: "/user-guide/backups" },
              { text: "Migrate from Hermes", link: "/user-guide/migrate-from-hermes" },
            ],
          },
          {
            text: "Built-in tools",
            collapsed: true,
            items: [
              { text: "File and search", link: "/tools/files-and-search" },
              { text: "Shell and background processes", link: "/tools/shell" },
              { text: "User questions", link: "/tools/ask" },
              { text: "Checkpoints and rewind", link: "/tools/checkpoint" },
              { text: "Todo plans", link: "/tools/todo" },
              { text: "Tool issue reports", link: "/tools/report-issue" },
              { text: "Web", link: "/tools/web" },
              { text: "Firecrawl", link: "/tools/firecrawl" },
              { text: "Media", link: "/tools/media" },
              { text: "Browser", link: "/tools/browser" },
              { text: "LSP", link: "/tools/lsp" },
              { text: "Eval", link: "/tools/eval" },
              { text: "Debugger", link: "/tools/debug" },
              { text: "omp delegate", link: "/tools/omp" },
              { text: "Computer use", link: "/tools/computer-use" },
            ],
          },
          {
            text: "Safety & security",
            collapsed: true,
            items: [
              { text: "Lemon safety", link: "/security/safety" },
              { text: "Agent safety contract", link: "/security/agent-safety-contract" },
              { text: "Secret obfuscation", link: "/security/secret-obfuscation" },
              { text: "Secrets migration guide", link: "/security/secrets-migration-guide" },
              { text: "Secrets and keychain contract", link: "/security/secrets-and-keychain" },
              { text: "Threat model & security posture", link: "/security/threat-model" },
            ],
          },
        ],
      },
      {
        text: "Configuration & CLI reference",
        collapsed: true,
        items: [
          { text: "Configuration", link: "/config" },
          { text: "Configuration registry", link: "/config-registry" },
          { text: "CLI & sessions", link: "/user-guide/cli" },
          { text: "TUI slash commands", link: "/user-guide/tui-commands" },
          { text: "Control-plane methods", link: "/reference/control-plane" },
          { text: "Skills reference", link: "/skills" },
          { text: "Skill manifest", link: "/reference/skill-manifest-v2" },
          { text: "Versioning & channels", link: "/release/versioning_and_channels" },
        ],
      },
      {
        text: "Integrations & channels",
        collapsed: true,
        items: [
          { text: "Add a channel", link: "/getting-started/add-a-channel" },
          { text: "lemon_gateway", link: "/platform/lemon_gateway" },
          { text: "Lemon in Tern", link: "/user-guide/tern" },
          { text: "OpenAI-compatible API", link: "/tools/openai-compatible-api" },
          { text: "ACP editor integration", link: "/tools/acp" },
          { text: "Extensions & MCP clients", link: "/extensions" },
          { text: "WASM extensions", link: "/tools/wasm" },
          { text: "Delegating to omp", link: "/user-guide/omp" },
          { text: "Persistent A2A peers", link: "/user-guide/a2a-peers" },
          { text: "Honcho memory", link: "/user-guide/honcho" },
        ],
      },
      {
        text: "Developers & contributors",
        collapsed: true,
        items: [
          {
            text: "Build on Lemon",
            collapsed: true,
            items: [
              { text: "Build your first agent", link: "/getting-started/build-your-first-agent" },
              { text: "Add a tool", link: "/getting-started/add-a-tool" },
              { text: "Persist memory", link: "/getting-started/persist-memory" },
              { text: "Typed bus events", link: "/platform/bus-events" },
            ],
          },
          {
            text: "Architecture",
            collapsed: true,
            items: [
              { text: "Overview", link: "/architecture/overview" },
              { text: "BEAM agents", link: "/beam_agents" },
              { text: "App boundaries", link: "/architecture_boundaries" },
              { text: "Execution policy", link: "/execution-policy" },
              { text: "Model selection", link: "/model-selection-decoupling" },
              { text: "Context management", link: "/context" },
              { text: "Bootstrap contract", link: "/assistant_bootstrap_contract" },
              { text: "Long-running harnesses", link: "/long-running-agent-harnesses" },
              { text: "Hot reload", link: "/runtime-hot-reload" },
              { text: "Telemetry", link: "/telemetry" },
              { text: "Error reporting", link: "/error-reporting" },
            ],
          },
          {
            text: "Contributing & testing",
            collapsed: true,
            items: [
              { text: "Public repo basics", link: "/contributor/public_repo_basics" },
              { text: "Ownership", link: "/contributor/ownership" },
              { text: "Testing", link: "/testing" },
              { text: "Deterministic test patterns", link: "/testing/deterministic-test-patterns" },
              { text: "Mix tasks", link: "/mix-tasks" },
              { text: "lemon_platform_test", link: "/platform/lemon_platform_test" },
            ],
          },
          {
            text: "Releases & packages",
            collapsed: true,
            items: [
              { text: "Package status", link: "/platform-split" },
              { text: "Hex packages", link: "/release/hex-packages" },
              { text: "Deployment flows", link: "/release/deployment_flows" },
              { text: "Release checklist", link: "/release/release_checklist_and_support_policy" },
            ],
          },
        ],
      },
      {
        text: "LemonSim & benchmarks",
        collapsed: true,
        items: [
          { text: "Quickstart", link: "/benchmarks/quickstart" },
          { text: "Platform guarantees", link: "/benchmarks/platform" },
          { text: "VendingBench", link: "/benchmarks/vending-bench" },
          { text: "Platform microbenchmarks", link: "/benchmarks/platform-microbenchmarks" },
          { text: "Run your own model", link: "/benchmarks/run-your-model" },
          { text: "Paired disclosure protocol", link: "/benchmarks/paired-disclosure" },
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
