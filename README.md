<p align="center">
  <img src="assets/beamcompass.svg" alt="BeamCompass" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/beamcompass"><img src="https://img.shields.io/badge/GitHub-beamcompass-181717?logo=github" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
</p>

# BeamCompass

**P01B local integration: source-only analysis and static HTML reporting.**

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
