# Changelog

## Unreleased — P02A authored, local acceptance pending

- Add source-only v2 typed entities, relations, evidence and manifest provenance
  with a separate core AST provider contract; retain snapshot/v1 APIs.
- Add exact snapshot-scoped references, source-only typed integrity checks and
  atomic v2 writes via `mix beamcompass.export`.
- Discover repository-root `monorepo/*/mix.exs` Poncho peers without executing
  target Mix files; add source-only negative and semantic ExUnit cases.
- Elixir, Mix and both-app checks have **not** been run for P02A. Local P02B
  must verify and fix before recording runtime acceptance.
