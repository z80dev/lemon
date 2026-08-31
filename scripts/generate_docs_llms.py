#!/usr/bin/env python3
"""Generate machine-readable Lemon documentation indexes for the docs site."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
PUBLIC = DOCS / "public"
SITE = "https://z80dev.github.io/lemon"

SECTIONS: tuple[tuple[str, tuple[tuple[str, str], ...]], ...] = (
    (
        "Start here",
        (
            ("index.md", "Product overview and paths into the documentation."),
            (
                "getting-started/quickstart.md",
                "Install, verify a provider-backed chat, resume the session, choose a next feature, and recover from failures.",
            ),
            ("install.md", "Release installer, source install, first-run setup, and supported platforms."),
            ("demo.md", "A deterministic local walkthrough for the runtime and interfaces."),
            ("user-guide/setup.md", "Configure providers, secrets, runtime settings, and channels."),
            ("user-guide/backups.md", "Create, verify, and safely restore private user-state backups."),
            ("user-guide/profiles.md", "Create, route, clone, export, and delete isolated specialist profiles."),
            ("support.md", "Diagnose startup, provider, runtime, and release problems."),
            ("compare.md", "Current product positioning and honest support boundaries."),
        ),
    ),
    (
        "Use Lemon",
        (
            ("user-guide/memory.md", "Durable local memory and recall behavior."),
            ("user-guide/skills.md", "Discover, install, audit, and use skills."),
            ("user-guide/adaptive.md", "Opt-in learning, synthesis, and rollout controls."),
            ("user-guide/honcho.md", "Configure the optional Honcho memory provider."),
            ("user-guide/migrate-from-hermes.md", "Preview and import supported Hermes state."),
            ("config.md", "Runtime configuration and environment-variable ownership."),
            ("mix-tasks.md", "Reference for Lemon Mix tasks."),
        ),
    ),
    (
        "Tools and interfaces",
        (
            ("tools/web.md", "Web search, fetch, and browser automation tools."),
            ("tools/execute-code.md", "Persistent Python RPC execution over allowlisted agent tools."),
            ("tools/media.md", "Media generation and artifact workflows."),
            ("tools/lsp.md", "Language-server diagnostics."),
            ("tools/acp.md", "ACP-shaped editor integration."),
            ("tools/openai-compatible-api.md", "OpenAI-compatible API surface."),
            ("extensions.md", "MCP, native, and WASM extension boundaries."),
            ("skills.md", "Skill format, discovery, trust, and lifecycle reference."),
        ),
    ),
    (
        "Architecture and operations",
        (
            ("architecture/overview.md", "System architecture and message flow."),
            ("beam_agents.md", "BEAM-native agent processes, supervision, and coordination."),
            ("context.md", "Context assembly, compaction, and overflow behavior."),
            ("model-selection-decoupling.md", "Provider and model selection design."),
            ("security/safety.md", "Approval, redaction, and execution safety boundaries."),
            ("testing.md", "Canonical test lanes and focused verification guidance."),
            ("telemetry.md", "Runtime telemetry and observability events."),
            ("release/versioning_and_channels.md", "CalVer releases and update channels."),
        ),
    ),
    (
        "Benchmarks",
        (
            ("benchmarks/quickstart.md", "Run a LemonSim benchmark locally."),
            ("benchmarks/platform.md", "Determinism, replay, and benchmark guarantees."),
        ),
    ),
)

FULL_ROOT_FILES = {
    "architecture_boundaries.md",
    "assistant_bootstrap_contract.md",
    "beam_agents.md",
    "compare.md",
    "config-registry.md",
    "config.md",
    "context.md",
    "demo.md",
    "error-reporting.md",
    "extensions.md",
    "index.md",
    "install.md",
    "long-running-agent-harnesses.md",
    "mix-tasks.md",
    "model-selection-decoupling.md",
    "runtime-hot-reload.md",
    "skills.md",
    "skills_v2.md",
    "subagent-parent-questions.md",
    "support.md",
    "telemetry.md",
    "testing.md",
    "why-beam-for-agents.md",
}
FULL_DIRECTORIES = (
    "architecture/",
    "benchmarks/",
    "for-dummies/",
    "getting-started/",
    "platform/",
    "reference/",
    "release/",
    "security/",
    "testing/",
    "tools/",
    "user-guide/",
)
def canonical_url(relative: str) -> str:
    path = relative.removesuffix(".md")
    if path == "index":
        path = ""
    return f"{SITE}/{path}"


def title_for(path: Path) -> str:
    content = path.read_text(encoding="utf-8")
    match = re.search(r"^#\s+(.+?)\s*$", content, flags=re.MULTILINE)
    if match:
        return re.sub(r"[`*_]", "", match.group(1)).strip()
    return path.stem.replace("-", " ").replace("_", " ").title()


def render_index() -> str:
    lines = [
        "# Lemon",
        "",
        "> Lemon is a local-first, BEAM-native AI agent runtime with durable sessions, memory, skills, supervised tools, automation, channels, and deterministic simulation.",
        "",
        f"- [Complete machine-readable documentation]({SITE}/llms-full.txt)",
        f"- [Source repository](https://github.com/z80dev/lemon)",
    ]
    for section, pages in SECTIONS:
        lines.extend(("", f"## {section}", ""))
        for relative, description in pages:
            path = DOCS / relative
            if not path.is_file():
                raise FileNotFoundError(f"curated docs page is missing: docs/{relative}")
            lines.append(f"- [{title_for(path)}]({canonical_url(relative)}): {description}")
    lines.extend(
        (
            "",
            "## Notes for agents",
            "",
            "- Public documentation describes supported behavior. Source modules and tests remain authoritative for implementation details.",
            "",
        )
    )
    return "\n".join(lines)


def full_documents() -> list[Path]:
    documents: list[Path] = []
    for path in DOCS.rglob("*.md"):
        relative = path.relative_to(DOCS).as_posix()
        if relative == "README.md":
            continue
        if (
            relative in FULL_ROOT_FILES or relative.startswith(FULL_DIRECTORIES)
        ):
            documents.append(path)
    return sorted(documents, key=lambda path: path.relative_to(DOCS).as_posix())


def render_full() -> str:
    lines = [
        "# Lemon complete documentation",
        "",
        "> Generated from Lemon's public product, user, tool, architecture, operations, and benchmark documentation.",
        "",
        f"Curated index: {SITE}/llms.txt",
        "",
    ]
    for path in full_documents():
        relative = path.relative_to(DOCS).as_posix()
        content = "\n".join(
            line.rstrip() for line in path.read_text(encoding="utf-8").splitlines()
        ).strip()
        lines.extend(
            (
                "---",
                "",
                f"Source: {canonical_url(relative)}",
                "",
                content,
                "",
            )
        )
    return "\n".join(lines)


def check_output(path: Path, expected: str) -> None:
    try:
        actual = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"missing generated docs asset {path.relative_to(ROOT)}: {error}", file=sys.stderr)
        raise SystemExit(1)
    if actual != expected:
        print(
            f"{path.relative_to(ROOT)} is stale; run scripts/generate_docs_llms.py",
            file=sys.stderr,
        )
        raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail instead of writing stale output")
    args = parser.parse_args()

    outputs = {
        PUBLIC / "llms.txt": render_index(),
        PUBLIC / "llms-full.txt": render_full(),
    }
    if args.check:
        for path, content in outputs.items():
            check_output(path, content)
        print(f"Machine-readable docs verified ({len(full_documents())} full-doc sources)")
        return

    PUBLIC.mkdir(parents=True, exist_ok=True)
    for path, content in outputs.items():
        path.write_text(content, encoding="utf-8")
        print(f"Wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
