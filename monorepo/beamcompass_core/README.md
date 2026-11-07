# BeamCompass Core

Source-only inspection and queries for Elixir/OTP projects, independent of Phoenix.
Requires Elixir 1.20.5 and Erlang/OTP 29.1.2.

```sh
mix deps.get
mix beamcompass.scan /path/to/project --out /tmp/snapshot.json
mix beamcompass.inventory /path/to/project
mix beamcompass.export /path/to/project --schema 2 \
  --project-id my-project --out /tmp/source.json
mix beamcompass.navigator /tmp/source.json \
  --query 'lens=effects&budget=32' --out /tmp/view.json
```

```elixir
{:ok, snapshot} = BeamCompass.scan("/path/to/project")
BeamCompass.inventory(snapshot)
{:ok, view} = BeamCompass.project(snapshot, lens: :effects, budget: 30)
:ok = BeamCompass.save(snapshot, "/tmp/snapshot.json")
{:ok, restored} = BeamCompass.load("/tmp/snapshot.json")

{:ok, source} = BeamCompass.export_source("/path/to/project", project_id: "my-project")
{:ok, request} = BeamCompass.projection_request(source, lens: :effects, budget: 12)
{:ok, projection} = BeamCompass.project_source(source, request)
{:ok, capsules} = BeamCompass.capsules_source(source)
{:ok, navigator} = BeamCompass.navigator_view(source, %{"lens" => "effects"})
```

The project namespace is caller supplied. Exact references are scoped to the
snapshot. V1 snapshots and typed V2 source exports have separate readers;
compatibility wrappers preserve validated payloads without semantic conversion.

Target Mix files, configuration, macros and modules are not executed. Source
candidates do not prove runtime behavior or absence. Projections report omitted
and unresolved records. Source anchors may contain starts without end positions.

Generate API documentation with `mix docs`.

[MIT License](LICENSE)
