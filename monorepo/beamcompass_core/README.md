<p align="center">
  <img src="assets/beamcompass_core.svg" alt="BeamCompass Core" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/beamcompass"><img src="https://img.shields.io/badge/GitHub-beamcompass-181717?logo=github" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
</p>

# BeamCompass Core

Source-grounded behavioral architecture analysis for Elixir/OTP applications.

## Contents

- [Overview](#overview)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Documentation](#documentation)
- [Changelog](CHANGELOG.md)
- [License](LICENSE)

## Overview

Part of [BeamCompass](https://github.com/nshkrdotcom/beamcompass), a conservative
Elixir/OTP architecture navigator using non-executing source AST inspection.
Dynamic dispatch, transitive effects and runtime behavior remain outside the
current analysis guarantees.

## Getting started

Requires Elixir 1.20.5 or later and a compatible Erlang/OTP release.
From this application's directory:

```sh
mix deps.get
mix compile
```

## Usage

```elixir
{:ok, snapshot} = BeamCompass.scan("../../fixtures/ledger_sample")
BeamCompass.inventory(snapshot)
{:ok, view} = BeamCompass.project(snapshot, lens: :effects, budget: 30)
```

```sh
mix beamcompass.scan ../../fixtures/ledger_sample --out /tmp/beamcompass.json
mix beamcompass.inventory ../../fixtures/ledger_sample
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

## Documentation

```sh
mix docs
```

The documentation menu includes this guide, API modules, Mix tasks, the
[changelog](CHANGELOG.md), and the [MIT license](LICENSE).

## Packaging

Build the Hex archive with:

```sh
MIX_ENV=prod mix hex.build
```

## License

MIT — Copyright (c) 2026 nshkrdotcom. See [LICENSE](LICENSE).

## P03A source-only causal capsules (pending local P03B Mix verification)

`BeamCompass.capsules_source/1`, `BeamCompass.projection_request/2` and
`BeamCompass.project_source/2` accept the **validated typed v2 source export**;
existing v1 `scan`, `project`, `save`, `load` and schemas remain unchanged.

```elixir
{:ok, exported} = BeamCompass.export_source("../../fixtures/ledger_sample", project_id: "fixture:ledger")
{:ok, request} = BeamCompass.projection_request(exported,
  lens: :effects, budget: 12, boundaries: [:effect, :intent, :state, :async, :unknown])
{:ok, projection} = BeamCompass.project_source(exported, request)
{:ok, capsules} = BeamCompass.capsules_source(exported)
```

The bounded projections and capsules are syntax-based candidates with exact
source-only reference expansion and preservation/omission/unknown receipts; they
are **not** observed traces or proofs of causality or correct interpreter
execution. The `budget` limits visible entity/relation refs (1–256), not capsule
summary/evidence/receipt metadata. `sends` stays unresolved even when an
explicit self-targeted handler pattern admits a `may_deliver_to` candidate.
The v2 API rejects wrong versions and namespaces. The actual runtime test of
this P03A implementation belongs to P03B; Elixir/Mix were unavailable during
A authoring. See the accompanying docset `contracts/projection.md`.
