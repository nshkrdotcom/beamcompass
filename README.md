<p align="center">
  <img src="assets/beamcompass.svg" alt="BeamCompass" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/beamcompass"><img src="https://img.shields.io/badge/GitHub-beamcompass-181717?logo=github" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
</p>

# BeamCompass

**P01B verified baseline; P02A typed v2 source implementation awaiting local P02B checks.**

BeamCompass is an Elixir/OTP behavioral architecture navigator. It constructs
source-grounded facts, conservative effect and intent candidates, provisional
handler capsules, limited projections and a self-contained HTML report.

This is **not** a complete OTP analyzer. The initial implementation uses only
non-executing source AST inspection. Dynamic dispatch, transitive effects,
precise message routing, state-machine inference and runtime truth remain future
work and are not asserted by current output.

## Structure

- `monorepo/beamcompass_core/`: independent Mix app, core API, scanner, snapshot codec,
  basic projections, CLI and ExUnit suite.
- `monorepo/beamcompass_web/`: independent Mix app depending only on the core through a
  path dependency; currently produces static HTML reports. Phoenix/LiveView is
  explicitly deferred to P05.
- `fixtures/ledger_sample/`: small OTP application for regression tests.
- `scripts/check.sh`: local quality gates for **both** Mix applications.
- `scripts/demo.sh`: generate the ledger sample report.

There is intentionally **no root `mix.exs`** (Poncho layout).

## Local validation

With Elixir >= 1.18 and an appropriate OTP version installed:

```sh
./scripts/check.sh
./scripts/demo.sh
```

`check.sh` runs `mix deps.get`, formatting, compilation with warnings-as-errors,
ExUnit, strict Credo, and Dialyzer in each independent project. P01B local
verification uses Elixir 1.20.4 and Erlang/OTP 29.1.2. The minimum declared
Elixir 1.18 compatibility has not been independently tested. See the separate
authoritative docset for exact command results and remaining scope.

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


## P02A typed source-only export (source authored; local verification pending)

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

This source implementation and its tests are **not yet runtime verified**:
Elixir/Mix were unavailable for P02A; local P02B must run and fix both Mix app
gates, the fresh-process export/consumer driver and source-safety acceptance.

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
