# BeamCompass

**Phase P01A source generation complete; Elixir runtime verification pending P01B.**

BeamCompass is an Elixir/OTP behavioral architecture navigator. It constructs
source-grounded facts, conservative effect and intent candidates, provisional
handler capsules, limited projections and a self-contained HTML report.

This is **not** a complete OTP analyzer. The initial implementation uses only
non-executing source AST inspection. Dynamic dispatch, transitive effects,
precise message routing, state-machine inference and runtime truth remain future
work and are not asserted by current output.

## Structure

- `beamcompass_core/`: independent Mix app, core API, scanner, snapshot codec,
  basic projections, CLI and ExUnit suite.
- `beamcompass_web/`: independent Mix app depending only on the core through a
  path dependency; currently produces static HTML reports. Phoenix/LiveView is
  explicitly deferred to P05.
- `fixtures/ledger_sample/`: small OTP application for regression tests.
- `scripts/check.sh`: local quality gates for **both** Mix applications.
- `scripts/demo.sh`: generate the ledger sample report.

There is intentionally **no root `mix.exs`** (Poncho layout).

## Local validation (first task for local agent)

With Elixir >= 1.18 and an appropriate OTP version installed:

```sh
./scripts/check.sh
./scripts/demo.sh
```

`check.sh` runs `mix deps.get`, formatting, compilation with warnings-as-errors,
ExUnit, strict Credo, and Dialyzer in each independent project. The commands
have **not** been executed in the ChatGPT.com environment. The first local
agent should fix any issues and update the separate implementation docset.

## Core API

```elixir
{:ok, snapshot} = BeamCompass.scan("../fixtures/ledger_sample")
BeamCompass.inventory(snapshot)
{:ok, view} = BeamCompass.project(snapshot, lens: :effects, budget: 30)
BeamCompass.explain(snapshot, hd(snapshot.facts).id)
BeamCompass.diff(snapshot, another_snapshot)
BeamCompass.save(snapshot, "/tmp/beamcompass-snapshot.json")
```

Inside `beamcompass_core`:

```sh
mix beamcompass.scan ../fixtures/ledger_sample --out /tmp/beamcompass.json
mix beamcompass.inventory ../fixtures/ledger_sample
```

Inside `beamcompass_web`:

```sh
mix beamcompass.report ../fixtures/ledger_sample --out /tmp/beamcompass.html
```

## Separate authoritative docset

The implementation docset is a **separate directory/repository** and should be
extracted at:

`~/p/g/n/brainstorms/shkrdotcom/docs/20261106/codebase_nav/impl_docs`

Start there with `README.md`, `control/state.json`, and
`control/NEXT_AGENT.md`. The docset carries the authoritative phase sequence,
acceptance criteria, approvals and handoff status. Keep it in sync with code.

## Safety and known limitations

- Target `mix.exs` and application source files are **read but never executed**.
- This scanner is a conservative source probe, not a complete BEAM fact graph.
- Source anchors identify start positions, not complete byte ranges.
- The first HTML report is a static inspection artifact, not a Phoenix app.
- No Elixir compilation, format, test, Credo or Dialyzer result is asserted yet.
- No `mix.lock` is supplied because dependencies have not been fetched.
