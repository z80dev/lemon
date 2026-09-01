# Pending workflow changes: sim removal

The Phase 1 removal of the lemon-sim product (see
[the September 2026 review](../architecture/review-2026-09.md)) also edits
four workflow files: `release.yml` loses the `sim_broadcast_platform` matrix
entries and the sim UI asset steps, `release-smoke.yml` loses its sim paths
and the two sim container jobs, `product-smoke.yml` loses `LEMON_SIM_UI_PORT`,
and `sim-bench.yml` is deleted.

Those edits are not on the branch yet. The GitHub App credential that pushed
the branch is not allowed to create or update files under
`.github/workflows/`, so the commit is carried here as a patch instead.

Until it is applied, the release, release-smoke and sim-bench workflows
still reference `apps/lemon_sim_ui` and will fail if they run.

## Apply it

From a checkout that can push workflow files:

```bash
git checkout claude/project-architecture-review-279nd0
git am docs/ci/sim-removal-workflows.patch
git rm docs/ci/sim-removal-workflows.patch docs/ci/sim-removal-workflows.md
git commit -m "ci: remove the pending workflow patch now that it is applied"
git push
```

Also remove this document's entry from `docs/catalog.exs` in that commit, or
`mix lemon.quality` will report a missing file. Granting the app the
`workflows` permission instead lets future sessions push such changes
directly.
