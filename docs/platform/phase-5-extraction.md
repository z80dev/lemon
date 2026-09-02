# Phase 5 — Product-Repo Extraction Readiness

Status: **historical investigation (2026-08-10; refreshed 2026-09-01).** Dependency facts read from `apps/*/mix.exs` and grepped call
sites against the tree at the time of writing. The coding_agent-blocker resolution below is a
**proposed decision (needs user sign-off)** — actually extracting a repo is a larger commitment
than the boundary work of Phases 1–4, so this document names and prices the blocker rather than
resolving it unilaterally.

This is the missing piece the §5 Phase 5 checklist assumed away: it lists a per-repo procedure
(`5.1`–`5.7`) but never states which product groups are *ready* to run it. The round-2 sweep
found that they are not equally ready — `lemon-sim` has a clean published-only dependency profile
while `coding-agent` is blocked on two unpublished apps — so the two are not interchangeable in
the extraction order.

## 1. Method

The nine published packages (post-D13) are:

`ai` → `lemon_ai`, `lemon_core`, `agent_core` → `lemon_agent`, `lemon_memory`, `lemon_media`,
`lemon_router`, `lemon_gateway`, `lemon_channels`, `lemon_platform_test`.

Everything else in `apps/` is either a **reference-runtime** app (stays in the platform repo,
unpublished: `lemon_control_plane`, `lemon_cli`, `lemon_web`, `lemon_automation`, `lemon_skills`,
`lemon_browser`, `lemon_lsp`) or a **product** app slated to leave (`coding_agent`,
`coding_agent_ui`, `lemon_mcp`, `lemon_evals`, `lemon_sim`, `lemon_sim_ui`, `lemon_tcg`).
The former X/Twitter satellite was deleted from the Lemon harness under D17 and
is no longer an extraction target.

An app is **extraction-ready** iff every one of its `in_umbrella` deps is either (a) a published
package, or (b) another app in the *same product group* (which leaves in the same `git filter-repo`
and stays an in-repo dep). Any `in_umbrella` dep on a reference-runtime app that stays behind is a
**blocker**: after extraction it would have to resolve from hex, and there is no hex release.

## 2. Per-product-group readiness

| Product group | App | `in_umbrella` deps | Blocker (unpublished dep) |
|---|---|---|---|
| **lemon-sim** | `lemon_sim` | lemon_core, agent_core, ai | **none** |
| | `lemon_sim_ui` | ai, lemon_core, **lemon_sim** | none (sim is intra-group) |
| | `lemon_tcg` | lemon_core, agent_core, ai, **lemon_sim** | none (sim is intra-group) |
| **coding-agent** | `coding_agent` | agent_core, ai, lemon_core, lemon_gateway, lemon_memory, lemon_platform_test*, **lemon_skills**, **lemon_browser** | **lemon_skills, lemon_browser** |
| | `coding_agent_ui` | **coding_agent**, lemon_core | none (coding_agent is intra-group) |
| | `lemon_mcp` | **coding_agent**, lemon_core, agent_core, **lemon_skills** | **lemon_skills** |
| | `lemon_evals` | agent_core, ai, **coding_agent**, lemon_core, **lemon_skills** | **lemon_skills** |

\* `lemon_platform_test` is a `only: :test, runtime: false` dep — the same test-only dependency
direction a third-party engine author has; not a runtime blocker.

**lemon-sim is ready now.** Every platform dep it touches is published; the only cross-app deps
inside the group (`sim_ui → sim`, `tcg → sim`) travel together in the extraction and remain in-repo
deps afterward. This confirms the D8 premise: sim has the cleanest profile and should be the
**first** product extracted — which means the §5 Phase 5 order (`coding-agent` first) is backwards
and should be flipped (see §5).

**coding-agent is blocked** on two reference-runtime apps, `lemon_skills` and `lemon_browser`.
`lemon_mcp` and `lemon_evals` inherit the `lemon_skills` blocker; `coding_agent_ui` is clean once
`coding_agent` itself moves.

## 3. Anatomy of the blocker

### lemon_skills — large, clean-deps, shared, tool-heavy

- **Size:** 19,442 LOC (`apps/lemon_skills/lib`). Not a leaf — it is the skill discovery /
  MCP-source / lockfile / installer / synthesis subsystem plus the agent tool implementations.
- **Its own deps are all published:** `lemon_core`, `lemon_memory`, `lemon_media`, `agent_core`,
  `ai`. After D7 moved the three X tools out, it has **zero** unpublished deps — so it is itself
  *publishable-clean*. The blocker is not that skills can't be published; it's whether we *want* to
  commit to semver on a 19k-LOC surface.
- **coding_agent's coupling is deep and wide:** 24 references across 8 files, ~20 distinct
  `LemonSkills.*` modules — including live agent tools (`Tools.MediaAnalyzeImage`,
  `MediaGenerateImage/Speech/Video`, `MediaStatus`, `MediaTranscribeAudio`, `Memory`,
  `MemoryTopic`, `SearchMemory`, `Kanban`, `ReadSkill`, `SkillManage`) and prompt/relevance
  surfaces (`Config`, `find_relevant`, `PromptView.render_relevant_skills`, `SkillView.from_entry`,
  `McpSource.discover_tools`). This is load-bearing, not incidental.
- **It is shared infrastructure, not product code.** Besides the coding-agent group
  (`coding_agent`, `lemon_mcp`, `lemon_evals`), it is consumed by the **reference runtime**:
  `lemon_control_plane` (25 refs) and `lemon_automation` (4 refs). The single `CodingAgent`
  reference inside `lemon_skills` is a moduledoc comment (`prompt_view.ex:91`), not a real reverse
  edge — so skills does not depend back on the product, but the runtime *does* depend on skills.

### lemon_browser — tiny, clean, leaf

- **Size:** 818 LOC. Deps: `lemon_core` + `jason` only — a leaf.
- **coding_agent's coupling is shallow:** 3 references, all in one file
  (`coding_agent/tools/browser.ex`), 3 modules: `LemonBrowser.Artifacts`, `.LocalServer`,
  `.RoutePolicy`.
- **Also shared with the runtime:** `lemon_control_plane` (5 refs). No reverse edge to CodingAgent.

## 4. Options and cost

The decisive fact for all four options is that **both skills and browser are shared between the
coding-agent product and the reference runtime that stays behind.** They are platform
infrastructure that the product happens to use, not product-owned code. That kills the "they leave
together" option and shapes the rest.

**(a) Publish `lemon_skills` + `lemon_browser` as packages 10 & 11.**
Both are clean (published-only deps), so the tarball mechanism (`hex_package.exs`) works with no
inversion. `lemon_browser` is trivial: 818 LOC, leaf, low API-churn risk — publishing it is one map
entry and metadata, on par with the D13 `lemon_media` decision. `lemon_skills` is the real cost: a
19k-LOC surface (discovery, MCP sources, lockfiles, installers, synthesis) whose API still churns;
publishing commits us to semver on all of it, and 4.4-style changelog discipline on every change.
*Viable, and the only option that doesn't add indirection, but it enlarges the published surface
substantially and needs an API-stabilization pass on skills first.*

**(b) Vendor / invert behind a behaviour** (the `RuntimeModules` / `EngineInfoBridge` pattern).
For `lemon_browser` this is cheap and clean: 3 modules behind one configured runtime module, exactly
the shape already used for doctor/media/lsp. For `lemon_skills` it is prohibitive: coding_agent
consumes ~20 modules including a dozen concrete agent *tools*; a behaviour that fronts all of that is
not a seam, it's a re-export of the whole app. *Attractive for browser, a non-starter for skills.*

**(c) Extract coding_agent *with* skills + browser as a larger product repo.**
**Not viable.** `lemon_control_plane` and `lemon_automation` (reference runtime, staying in the
platform repo) both depend on `lemon_skills`, and `control_plane` depends on `lemon_browser`. If
those apps leave with coding_agent, the reference runtime breaks and would itself need skills/browser
inverted or published — i.e. you land back in (a)/(b) plus a broken runtime in the interim.

**(d) Defer coding_agent extraction** until external demand, keeping it in the umbrella.
Zero cost now; coding_agent is not the flagship (sim is, D8), so nothing forces its extraction on
the Phase 5 timeline. The umbrella keeps building it against `in_umbrella` deps exactly as today.

## 5. Recommendation

**Two-part, argued from the asymmetry in §3:**

1. **Extract `lemon-sim` first (unblocked flagship), not `coding-agent`.** Flip the §5 Phase 5
   order. Sim is ready today (§2), it is the D8 flagship, and running the `5.1`–`5.7` procedure on
   the clean case first de-risks the tooling (`git filter-repo`, CI port, nightly integration lane)
   before the hard case.

2. **For the coding-agent blocker, split the two deps by their cost:**
   - **`lemon_browser`: publish it as a package** (cheap, clean, leaf — same rationale as D13 for
     `lemon_media`). Inversion (b) is also fine here and slightly smaller-surface, but publishing is
     more honest since control_plane consumes it too and a package serves both.
   - **`lemon_skills`: publish it as a package as well (option a), *gated on an API-stabilization
     pass*, and defer coding-agent's extraction until that pass lands.** Reject invert (b) — the
     20-module, tool-heavy surface makes a fronting behaviour a re-export, not a seam. Reject
     leave-together (c) — the reference runtime needs skills. Skills is genuine shared platform
     infrastructure with clean deps; the only real question is committing to its API, so the work is
     stabilization, not architecture. Until that lands, **defer (d)** coding-agent — it is not the
     flagship and nothing on the timeline forces it.

Net: sim extracts on the current Phase 5 tooling now; browser and skills become published packages
10 & 11 when coding-agent's turn comes; coding-agent, mcp, evals, and coding_agent_ui follow once
skills' API is release-worthy. This keeps the "publish, don't invert, for shared clean-dep
infrastructure" principle consistent with D13, and avoids bolting a 20-module behaviour onto the
product boundary.

## 6. Open items this surfaces

- **Package count grows from 9 to 11** if the recommendation is accepted (`lemon_skills`,
  `lemon_browser` join). Both need the 4.1 metadata treatment (`hex_package.exs` wrapping,
  CHANGELOG, LICENSE, docs) and a slot in the 4.3 publish order (after their deps: browser after
  core; skills after media/memory/agent).
- **`lemon_skills` API-stabilization is now a named prerequisite** for coding-agent extraction, not
  a hidden one. Scope: the ~20 modules coding_agent/mcp/evals consume (§3) are the public surface
  that has to settle; the installer/lockfile/synthesis internals can stay `@moduledoc false`.
- Hex-name availability for `lemon_skills` / `lemon_browser` not yet verified (E4 checked the
  original 8 + media). Verify before reserving.
