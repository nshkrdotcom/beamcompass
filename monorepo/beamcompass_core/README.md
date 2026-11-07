<p align="center">
  <img src="assets/beamcompass_core.svg" alt="BeamCompass Core logo" width="200">
</p>

# BeamCompass Core

<p>
  <img src="https://img.shields.io/badge/Elixir-1.20.5-4B275F" alt="Elixir 1.20.5">
  <img src="https://img.shields.io/badge/Erlang%2FOTP-29.1.2-A90533" alt="Erlang/OTP 29.1.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"></a>
</p>

BeamCompass Core reads Elixir/OTP source without running the inspected application. It can save a fact inventory or export a graph of entities, relations, and evidence. Both the Mix commands and Elixir API work without Phoenix.

## Get started

Use Elixir **1.20.5** and Erlang/OTP **29.1.2**. Run these commands in `monorepo/beamcompass_core`:

```sh
mix deps.get

# Count the source findings.
mix beamcompass.inventory ../../fixtures/ledger_sample

# Save a fact snapshot.
mix beamcompass.scan ../../fixtures/ledger_sample --out ledger-facts.json

# Export a source graph for queries and the browser navigator.
mix beamcompass.export ../../fixtures/ledger_sample \
  --schema 2 --project-id ledger-sample --out ledger-source.json \
  --manifest ledger-inputs.json

# Select an effects view from the saved source graph.
mix beamcompass.navigator ledger-source.json \
  --query 'lens=effects&budget=32' --out ledger-view.json
```

In `../../fixtures/ledger_sample`, the reducer describes effects as data and the executor performs them. The scan keeps those findings separate.

## CLI commands

| Command | Purpose | Output |
| --- | --- | --- |
| `mix beamcompass.inventory PATH` | Count facts by kind | Terminal |
| `mix beamcompass.scan PATH [--out FILE]` | Scan source into a fact snapshot | `beamcompass-snapshot.json` by default |
| `mix beamcompass.export PATH --schema 2 --project-id ID --out FILE [--manifest INPUTS.json]` | Export a typed source graph | JSON snapshot; optional file-hash and extractor-settings manifest |
| `mix beamcompass.navigator SNAPSHOT.json [--query QUERY] [--out FILE]` | Read a validated graph and select a navigation view | Standard output, or JSON file with `--out` |

Choose a nonempty `--project-id` and reuse it across exports of the same project. The exporter supports schema `2` and source evidence only.

## Two snapshot formats

**Fact snapshot (`mix beamcompass.scan`, schema 1)**

`BeamCompass.scan/1` returns `%BeamCompass.Model.Snapshot{}` with `projects`, `facts`, `capsules`, and `issues`. Facts record handlers, calls, effect sites, intent candidates, and unresolved dispatch. Each fact has an ID and source location. Capsules collect findings from one handler clause; they are not execution traces.

Read and write this format with `BeamCompass.load/1` and `BeamCompass.save/2`. `BeamCompass.project/2` supports `:behavior`, `:effects`, and `:state` and counts the nodes excluded by the budget.

**Source graph (`mix beamcompass.export`, schema 2)**

The graph has exact project and snapshot IDs, plus `entities`, `relations`, `evidence`, `issues`, `limitations`, and a `manifest`. Entities describe modules, functions, actors, triggers, transitions, effects, effect intents, decisions, and failure boundaries. Relations say whether a link is `resolved`, `possible`, or `unresolved`.

Every evidence record names its provider and gives a path, source SHA-256, and start location. The manifest records source and configuration digests, the toolchain, and providers. The optional sidecar manifest adds hashes for individual files and extractor settings.

Save this format with `BeamCompass.save_source/2`. To create it, scan the source checkout with `BeamCompass.export_source/2`; a fact snapshot cannot supply the missing evidence.

## Work with fact snapshots in Elixir

```elixir
{:ok, snapshot} = BeamCompass.scan("../../fixtures/ledger_sample")

counts = BeamCompass.inventory(snapshot)
{:ok, view} = BeamCompass.project(snapshot, lens: :effects, budget: 30)

fact = hd(snapshot.facts)
{:ok, details} = BeamCompass.explain(snapshot, fact.id)

:ok = BeamCompass.save(snapshot, "ledger-facts.json")
{:ok, restored} = BeamCompass.load("ledger-facts.json")
comparison = BeamCompass.diff(snapshot, restored)
```

`view["receipts"]` reports visible and omitted counts. `details["anchor"]` contains the source location. `comparison["added"]` and `comparison["removed"]` compare fact IDs; they do not claim a change in executed behavior.

## Query a source graph in Elixir

```elixir
{:ok, source} =
  BeamCompass.export_source("../../fixtures/ledger_sample", project_id: "ledger-sample")

:ok = BeamCompass.save_source(source, "ledger-source.json")

{:ok, request} =
  BeamCompass.projection_request(source,
    lens: :effects,
    budget: 32,
    boundaries: [:effect, :unknown]
  )

{:ok, projection} = BeamCompass.project_source(source, request)
{:ok, capsules} = BeamCompass.capsules_source(source)
{:ok, navigator} = BeamCompass.navigator_view(source, %{"lens" => "effects", "budget" => "32"})
```

Graph projections have four lenses: `behavior`, `effects`, `state`, and `failure`. A budget allows 1 to 256 visible entity/relation records. Requests can set an exact `focus`, preserve named references, or require boundaries such as `:effect`, `:intent`, `:state`, `:failure`, `:trigger`, and `:unknown`.

The result separates `visible`, `omitted`, `collapsed`, and `unknown` records. Its receipt says which references were preserved, which were not, and why. It also lists missing boundaries and source-path witnesses. Showing a record does not prove a connected path; broken or cut paths remain unsatisfied.

### Inspect an exact reference

```elixir
effect = Enum.find(source["entities"], &(&1["kind"] == "effect"))
{:ok, reference} = BeamCompass.source_reference(source, "entity", effect["id"])
{:ok, record} = BeamCompass.resolve_source_reference(source, reference)
```

References include `project_id`, `snapshot_id`, object kind, object ID, and evidence IDs. The resolver checks those exact fields, not a label or a nearby revision. It works for entities, relations, and evidence.

### Answer a source-scoped question

```elixir
question = %{
  "id" => "executor-effects",
  "kind" => "effect_sites",
  "subject" => "LedgerSample.EffectExecutor.execute/1"
}

{:ok, answer} = BeamCompass.answer_source(source, question)
```

Question kinds are `message_receivers`, `state_writes`, `effect_intents`, `effect_sites`, `intent_interpreters`, and `failure_restarts`. Answers include exact references and unresolved relations. To score answers against your own expected targets and unknown outcomes, use `BeamCompass.benchmark_source/2`.

## Compare and retain exports

Pass two source-graph exports with the same `project_id` to `BeamCompass.compare_source/2`:

```elixir
{:ok, changes} = BeamCompass.compare_source(before_source, after_source)
```

The change set records additions, removals, and possible matches. Identical labels are not enough to match records across snapshots. This comparison cannot establish runtime impact or the order of Git revisions.

For a commit-verified export, scan a Git repository root with `BeamCompass.export_source_git/2`:

```elixir
{:ok, pinned} = BeamCompass.export_source_git("/path/to/git-checkout", "my-project")
```

Every scanned source file must match its copy in `HEAD`. Modified or untracked source files are refused. The manifest records the commit.

To store a snapshot with its input-file hashes under a content-derived ID:

```elixir
{:ok, saved} =
  BeamCompass.archive_source("../../fixtures/ledger_sample", "ledger-sample", "./archive")

{:ok, bundle} = BeamCompass.load_source_archive("./archive", saved["content_id"])
{:ok, archived_source} = BeamCompass.Behavior.Archive.rehydrate(bundle)
```

The archive holds the graph and file hashes, not the source files themselves. `BeamCompass.invalidate_source/5` uses old and new file manifests plus declared dependencies to identify stale cached analyses. You still need a fresh source scan.

## Source coverage and limits

Core finds standalone Mix projects, immediate Mix-project siblings, and projects under `monorepo/*/`. It reads `lib/**/*.ex` and `lib/**/*.exs`. It does not run target `mix.exs`, configuration, modules, or macros. Parse errors are recorded without discarding findings from other files.

The source reader refuses symlinks and imposes these limits:

| Guard | Limit |
| --- | ---: |
| Source files | 2,000 |
| Individual source file | 2 MiB |
| All source bytes | 32 MiB |
| Parser time per file | 3 seconds |

Parsing uses a time- and memory-limited BEAM worker, not an OS sandbox. Source syntax cannot establish dynamic dispatch, macro-generated behavior, message delivery, state ownership, or executed effects. Anchors may lack end positions. An unreported effect is not proof that no effect can occur.

## Development

```sh
mix test
mix format --check-formatted
mix docs
```

The [repository README](../../README.md) covers the other application and the end-to-end entry points. For the LiveView navigator and HTML reporting, see [BeamCompass Web](../beamcompass_web/README.md).

## License

[MIT License](LICENSE)
