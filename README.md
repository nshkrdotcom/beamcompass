<p align="center">
  <img src="assets/beamcompass.svg" alt="BeamCompass" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/beamcompass"><img src="https://img.shields.io/badge/GitHub-beamcompass-181717?logo=github" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
</p>

# BeamCompass

**P04B runtime verified; P05A Phoenix navigator source implemented pending local measured gates.**

BeamCompass is an Elixir/OTP behavioral architecture navigator. It constructs
source-grounded facts, conservative effect and intent candidates, provisional
handler capsules, limited projections and a self-contained HTML report.

This is **not** a complete OTP analyzer. The initial implementation uses only
non-executing source AST inspection. Dynamic dispatch, transitive effects,
precise message routing, state-machine inference and runtime truth remain future
work and are not asserted by current output.

## Structure

- `monorepo/beamcompass_core/`: independent Mix app, core API, scanner, snapshot codec,
  v2 projections and snapshot-aware source navigator, CLI and ExUnit suite.
- `monorepo/beamcompass_web/`: independent Mix app depending only on the core through a
  path dependency; preserves static HTML reports alongside a P05A Phoenix/LiveView
  source navigator (real server/browser acceptance pending local toolchain).
- `fixtures/ledger_sample/`: small OTP application for regression tests.
- `scripts/check.sh`: local quality gates for **both** Mix applications.
- `scripts/demo.sh`: generate the ledger sample report.

There is intentionally **no root `mix.exs`** (Poncho layout).

## Local validation

With Elixir >= 1.20.5 and an appropriate OTP version installed:

```sh
./scripts/check.sh
./scripts/demo.sh
```

`check.sh` runs `mix deps.get`, formatting, compilation with warnings-as-errors,
ExUnit, strict Credo, and Dialyzer in each independent project. P01B local
verification used Elixir 1.20.4 and Erlang/OTP 29.1.2. The current minimum
required Elixir version is 1.20.5; `.tool-versions` selects Elixir 1.20.5
with Erlang/OTP 29.1.2 for asdf. See the separate authoritative docset for
exact command results and remaining scope.

## Core API

```elixir
{:ok, snapshot} = BeamCompass.scan("../../fixtures/ledger_sample")
BeamCompass.inventory(snapshot)
{:ok, view} = BeamCompass.project(snapshot, lens: :effects, budget: 30)
BeamCompass.explain(snapshot, hd(snapshot.facts).id)
BeamCompass.diff(snapshot, another_snapshot)
BeamCompass.save(snapshot, "/tmp/beamcompass-snapshot.json")
```

Inside `monorepo/beamcompass_core`:

```sh
mix beamcompass.scan ../../fixtures/ledger_sample --out /tmp/beamcompass.json
mix beamcompass.inventory ../../fixtures/ledger_sample
```

Inside `monorepo/beamcompass_web`:

```sh
mix beamcompass.report ../../fixtures/ledger_sample --out /tmp/beamcompass.html
```


## P02A typed source-only export (historical implementation; verified through P04B)

P02A adds a separate v2 envelope, keeping the default v1 scanner, snapshot
format, save/load calls, and web report unchanged. Example, from
`monorepo/beamcompass_core`:

```sh
mix beamcompass.export ../../fixtures/ledger_sample --schema 2 \
  --project-id fixture:ledger --out /tmp/beamcompass-v2.json \
  --manifest /tmp/beamcompass-v2.inputs.json
```

```elixir
{:ok, snapshot_v2} = BeamCompass.export_source("../../fixtures/ledger_sample", project_id: "fixture:ledger")
entity = hd(snapshot_v2["entities"])
{:ok, exact_ref} = BeamCompass.source_reference(snapshot_v2, "entity", entity["id"])
{:ok, ^entity} = BeamCompass.resolve_source_reference(snapshot_v2, exact_ref)
BeamCompass.save_source(snapshot_v2, "/tmp/beamcompass-v2.json")
```

The namespace must be persistent and supplied by the caller. Only **source**
evidence and schema **2** are accepted. The snapshot hash and exact object refs
are version-scoped, not semantic identity across revisions. Source evidence
records producer version, file hash, start line/column and derivation inputs.
End coordinates are null when unverified. `performs_effect` only resolves to
a *syntactic effect call site*, not proof of runtime execution; intent tuples
remain unresolved as to performer. Aliased/external calls may remain unknown.
All target code, Mix scripts, macros and on_load remain unexecuted by the scan.

The v2 source contract was subsequently verified locally through P04B.
The separate P05A LiveView/navigator implementation is not runtime-verified until
its measured local P05 gates pass; see the web README and `scripts/verify_p05.sh`.

## Separate authoritative docset

The implementation docset is a **separate directory/repository** and should be
extracted at:

`~/p/g/n/brainstorms/nshkrdotcom/docs/20261106/beamcompass/impl_docs`

Start there with `README.md`, `control/state.json`, and
`control/NEXT_AGENT.md`. The docset carries the authoritative phase sequence,
acceptance criteria, approvals and handoff status. Keep it in sync with code.

## Safety and known limitations

- Target `mix.exs` and application source files are **read but never executed**.
- This scanner is a conservative source probe, not a complete BEAM fact graph.
- Source anchors identify start positions, not complete byte ranges.
- The first HTML report is a static inspection artifact, not a Phoenix app.
- P01B verifies the limited source-mode slice; full OTP analysis remains future work.
- Dependency lockfiles are supplied for both Mix applications.

## Documentation and licensing

- [Core application](monorepo/beamcompass_core/README.md) · [Core changelog](monorepo/beamcompass_core/CHANGELOG.md)
- [Report application](monorepo/beamcompass_web/README.md) · [Report changelog](monorepo/beamcompass_web/CHANGELOG.md)
- [MIT License](LICENSE) — Copyright (c) 2026 nshkrdotcom

## P03A additive source-only projections

Core now authors bounded, expandable source-possible causal capsules plus
`projection_request/2` and `project_source/2`, based on verified v2 source
exports without changing the v1 renderer/codec. Critical boundary preservation,
unknowns and budget omissions are explicit, never inferred as runtime truth.
This A archive has **not** run Mix/ExUnit/Credo/Dialyzer; P03B verifies/fixes
against the operator-committed source and docs. See
`impl_docs/contracts/projection.md` at the documented external docset location.

### P05A standalone navigator source implementation

The trusted `monorepo/beamcompass_web` app has a new Phoenix LiveView
`/navigator` route and source-only TypeScript stage. All identities and
preservation/uncertainty receipts are owned by
`monorepo/beamcompass_core/lib/beamcompass/analysis/navigator.ex` and exported
without Phoenix by `mix beamcompass.navigator`; v1 offline HTML reports remain
available. See the web and core READMEs for setup and source-safety limits.
`sh scripts/verify_p05.sh` is the strict local acceptance runner (Mix tests,
Credo, Dialyzer and docs for both trusted siblings; npm build; actual live
Chromium/headless/browser/a11y test). It requires the separately tracked parent
docset specified in `P05_DOCSET_ROOT` and a full Elixir/npm/Chromium toolchain.
The P05 source-only CI workflow runs trusted-app checks and real browser parity
with `P05_SOURCE_CI_ONLY=1`, explicitly leaving external parent-docset gates
unrun. The complete local release runner requires that separate docset; a green
source CI run alone is never the P05A/P05B controller exit. No CI run is
claimed by A.

## P06 source-only hardening (A implementation, not release-qualified)

Frozen P06 tasks now have source/test implementations: bounded nonexecuting
Elixir source scanning (`BeamCompass.Source.Safety`), fail-closed symlink and
oversize guards, parser worker heap/timeout, v1 atomic persistence and v2
content-addressed archive recovery, exact v1/v2 compatibility transport
(`BeamCompass.wrap_compatibility/1`, `rehydrate_compatibility/1`), explicit
cross-version semantic promotion refusal, and release eligibility checks.
Technical parser limits are **not** owner-approved performance or recovery SLOs;
no compiled/observed target analysis, OS sandbox, publisher signature or Grand
approval engine is provided.

`python3 scripts/p06_release.py --source-root . --check-reproducible` exercises
an unsigned deterministic source release and content integrity only.
`python3 scripts/p06_corpus.py --source-root . --docset-root <committed-docset>
--out <output>` attempts two real source-only trusted-core Mix exports per
bundled corpus with independent Python reader checks and sampled per-process
RSS/wall measurements; `--inventory-only` is explicitly NOT passing exporter
or scale evidence. The included apps are two actual first-party apps and one
controlled ledger fixture; a separately documented, independently acquired
project must be provided as `--external-project-root` and
`--external-provenance` to qualify broader real corpora. Never enter an
inspected target with Mix or evaluate its config/modules/macros.

The authoritative strict B run is `sh scripts/verify_p06.sh` on the user-committed
source with separately user-committed parent docset and real owner-approved
budgets/recovery evidence. It intentionally refuses a green release when these
are missing. The P06 source-only CI workflow is only a subset; P05 live
browser/CLI parity must be rerun on a real trusted local Elixir+Node toolchain.
As supplied in A, Elixir/Mix is unavailable, no owner-approved scale/recovery
values exist, and P06A remains Active pending six measured acceptance exits.
