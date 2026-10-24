# Native Mac development and cleanup

## Workspace policy

I develop on macOS ARM64 without a VM or container platform. Tools and generated data belong in the existing project workspace rather than scattered system installations. I do not add global shell configuration, Homebrew, launch agents, database services or global Git settings for this challenge.

The checkout is one directory inside a surrounding workspace. From the workspace root:

| Location | Purpose |
|---|---|
| `multicore-server-challenge/` | Repository and source |
| `work/tools/` | Project-local Go, GitHub CLI, later PostgreSQL/libpq |
| `work/cache/` | Go/Zig build and dependency caches |
| `work/runtime/` | Database cluster, socket files, logs, process metadata |
| `work/tmp/` | Temporary downloads and scratch files |
| `outputs/` | Review copies of documents and selected deliverables |

These are local workspace conventions. The eventual submission must build from its own folder on clean Ubuntu without referring to this Mac's absolute paths. Runtime configuration comes from DATABASE_URL, JWT_SECRET, HOST and PORT.

## Existing tools

Zig 0.17.0 and VS Code were already installed. Preparation added project-local Go 1.27.3 and GitHub CLI 2.103.2 from official, SHA-256-checked distributions, plus the official Zig VS Code extension 0.7.0. No PostgreSQL installation has been made yet.

The VS Code workspace directs new integrated terminals to local GOCACHE, GOMODCACHE, GOPATH, ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR and TMPDIR paths. PSQL_HISTORY is local too. GOTOOLCHAIN=local avoids silently downloading another Go compiler. Existing terminals and commands launched elsewhere do not automatically inherit this environment. Editor-managed tools need the same cache-location check before activation.

## Planned PostgreSQL setup

Use one pinned PostgreSQL 18 distribution with both server tools and libpq, installed/extracted under work/tools if it is relocatable and meets the test requirements. Keep data, sockets and logs under work/runtime. Start and stop it explicitly with pg_ctl, bind locally on a dedicated port, and do not register an automatic service.

A local source build is a candidate because the Mac already has the basic compiler, SDK, make, flex, bison and Perl tools. The exact patch release, checksums, optional dependencies and collation are still to be verified. I will not install a chain of extra packages merely to rescue an unsuitable distribution. The Linux submission build must also pin its client dependency and build from source where required by the challenge.

Use development data first. Full-seed tests need extra space for template copies, generated seed files, WAL and logs. The reported database size is not the peak disk requirement. Avoid multiple full copies by default and record disk use around longer tests.

## Validation plan

1. Confirm the unmodified reference server and test harness work on the chosen PostgreSQL cluster.
2. Run the unchanged conformance suite against a fresh development-seed copy.
3. Repeat against a fresh full-seed copy once the implementation is complete.
4. Compare normalized transcripts with the development golden transcript.
5. Add targeted HTTP-framing, concurrent mutation, rollback, commit visibility, disconnect and database-recovery checks.
6. Measure local candidates against the same load with alternating A/B order. Keep raw results, commit IDs and resource conditions.

Expected future commands from the repository root, once the environment and scripts exist:

```sh
bash seed/make-seed.sh --dev
bash test/run.sh submissions/zig-reactor-Chemske
bash seed/make-seed.sh
TEMPLATE=conduit_seed bash test/run.sh submissions/zig-reactor-Chemske
```

These are a runbook, not commands executed for this server. Seed creation replaces the named seed database, so it belongs in the dedicated project cluster. Test/run creates and removes a temporary database. Load tests need separate disposable copies because they mutate data. Local development-seed load runs use 10,000 seeded articles rather than the full-data default.

The Mac's six cores and 8 GiB RAM cannot reproduce the official Linux target. Keep local load within host limits, monitor generator saturation and memory pressure, and never label local capacity as an official score. Linux CI is a required compatibility check; the organiser's benchmark determines the ranking. No remote server rental is part of this plan.

## Current footprint and cleanup inventory

At the research checkpoint, work used roughly 414 MiB and the checkout roughly 6.9 MiB before these documents. Download archives inside work/tools account for about 78 MiB and can be removed once their extracted tools are no longer in doubt. They have not been deleted during research.

Earlier preparation also used default cache locations outside this workspace:

| Location | Observed size | Treatment |
|---|---:|---|
| `~/.cache/zig` | 46 MiB | Review challenge-generated entries; may include pre-existing content |
| `~/Library/Caches/go-build` | 136 MiB | Review before deletion; do not assume exclusive ownership |
| `~/go/pkg/mod` | 51 MiB | Contains dependencies fetched during preparation; inspect before removal |
| `~/.vscode/extensions/ziglang.vscode-zig-0.7.0` | 1.4 MiB | Added Zig extension; removable through VS Code if no longer wanted |

I will not delete entire shared caches without confirming their contents. The pre-existing Zig installation, VS Code and GitHub credentials are not disposable challenge files. macOS and the editors can also retain normal metadata and history; a contained workspace is not a promise of zero operating-system traces.

Cleanup order: stop only the project server and database cluster; preserve or push useful source and results; remove project-generated work; optionally remove the added extension and reviewed external cache entries. Never remove a live database directory before stopping its server. Keep this inventory current as setup changes.

## Repository policy

All proposed submission files stay under submissions/zig-reactor-Chemske. Shared challenge files remain unchanged. Documentation is in English and distinguishes intended behaviour from verified behaviour. Reused source keeps its licence and attribution; no invented benchmark or test result belongs in the README.

The existing remote branch name zig-httpz-chemske reflects an earlier candidate and does not describe the selected reactor design. It can be renamed before submission; no PR is being opened during research.
