<p align="center">
  <img src="assets/beamcompass.svg" alt="BeamCompass logo" width="160">
</p>

# BeamCompass

![Elixir 1.20.5](https://img.shields.io/badge/Elixir-1.20.5-4B275F) ![Erlang/OTP 29.1.2](https://img.shields.io/badge/Erlang%2FOTP-29.1.2-A90533)

BeamCompass reads an Elixir/OTP codebase without running it. It identifies handlers, message sends, effect sites, possible state changes, and calls it cannot resolve. Each finding points back to the source.

Run a Mix command, save a JSON snapshot, open an HTML report, or follow the graph in Phoenix LiveView.

## Try it on the included sample

The sample ledger application has a GenServer, a pure reducer, and a separate effect executor. You can inspect all three without starting the app.

From the repository root, generate an HTML report:

```sh
cd monorepo/beamcompass_web
mix deps.get
mix beamcompass.report ../../fixtures/ledger_sample --out ledger-report.html
```

Open `monorepo/beamcompass_web/ledger-report.html` in a browser. It shows behavior, effects, and state views, with the findings behind each. No web server is needed.

To export a graph for the CLI or LiveView navigator, start again from the repository root:

```sh
cd monorepo/beamcompass_core
mix deps.get
mix beamcompass.export ../../fixtures/ledger_sample \
  --schema 2 --project-id ledger-sample --out ledger-source.json
mix beamcompass.navigator ledger-source.json \
  --query 'lens=effects&budget=32' --out ledger-view.json
```

`ledger-source.json` holds the source graph. `ledger-view.json` contains a selected view with limits and omissions recorded. See the [Web README](monorepo/beamcompass_web/README.md) to open the graph in a browser.

## Pick an output

| What you need | Command or interface | Result |
| --- | --- | --- |
| An inventory of source facts | `mix beamcompass.inventory PATH` | Counts by fact kind in the terminal |
| A portable fact snapshot | `mix beamcompass.scan PATH --out FILE` | JSON with facts, handler capsules, and scan issues |
| A source graph with evidence | `mix beamcompass.export PATH --schema 2 --project-id ID --out FILE` | JSON with entities, relations, source evidence, and provenance |
| A headless graph view | `mix beamcompass.navigator SNAPSHOT.json --query QUERY` | JSON with exact selections, visible records, and omission receipts |
| A standalone report | `mix beamcompass.report PATH --out FILE` | One HTML file with three inventory views |
| An interactive browser | `/navigator` in BeamCompass Web | Four lenses, source evidence, semantic zoom, and revision navigation |

These are separate formats. Both navigators accept **source graph exports (schema 2)**, not the fact snapshot saved by `mix beamcompass.scan`.

## Where to go next

| Project | What it contains | Documentation |
| --- | --- | --- |
| `monorepo/beamcompass_core` | Source scanner, JSON exports, projections, exact references, comparisons, archives, and headless navigation | [Core README](monorepo/beamcompass_core/README.md) |
| `monorepo/beamcompass_web` | Phoenix LiveView navigator and standalone HTML report generator | [Web README](monorepo/beamcompass_web/README.md) |
| `fixtures/ledger_sample` | A small OTP application for trying the commands | [Sample source](fixtures/ledger_sample/lib/ledger_sample) |

Core and Web are separate Mix applications; the repository root has no `mix.exs`. The pinned toolchain uses Elixir **1.20.5** and Erlang/OTP **29.1.2**. Web asset builds use Node.js **22**.

## What the findings mean

BeamCompass parses source files without loading the inspected application. A call site shows where a call appears, not whether it ran. A message send does not prove delivery. An intent tuple does not prove an effect happened.

Exports report uncertain relationships, missing targets, parse errors, and records cut by a view budget. Source locations include a path, line, and column; end positions can be unknown. Parsing is resource-limited, but it is not an operating-system sandbox.

## License

[MIT License](LICENSE)
