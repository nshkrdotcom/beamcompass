#!/bin/sh
# FULL LOCAL P06 release-verification gate: only trusted sibling applications run Mix.
# No scanned Mix/config/modules/macros/mutants/Grand engine is ever run.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
: "${P06_DOCSET_ROOT:=/home/home/p/g/n/brainstorms/nshkrdotcom/docs/20261106/beamcompass/impl_docs}"
: "${P06_LOG_ROOT:=$(mktemp -d /tmp/beamcompass-p06-release.XXXXXXXX)}"
: "${P06_OWNER_APPROVAL:=$P06_LOG_ROOT/owner-approved-thresholds.json}"
: "${P06_RECOVERY_EVIDENCE:=$P06_LOG_ROOT/real-fault-recovery.json}"
mkdir -p "$P06_LOG_ROOT"
[ -f "$P06_DOCSET_ROOT/control/PHASE_A_SCOPE_GATE.md" ] || {
  echo 'P06 BLOCKED: independently user-committed parent-docset checkout is absent' >&2
  exit 3
}
command -v mix >/dev/null || { echo 'P06 UNRUN: Mix/Elixir absent' >&2; exit 127; }
command -v npm >/dev/null || { echo 'P06 UNRUN: npm absent' >&2; exit 127; }
# P05 verifier runs BOTH trusted apps deps.get/format/compile/test/credo/dialyzer/docs,
# actual npm ci/check/build, live Phoenix server browser+CLI parity and axe/Orca tests.
P05_DOCSET_ROOT="$P06_DOCSET_ROOT" P05_LOG_ROOT="$P06_LOG_ROOT/p05-live" \
  sh "$root/scripts/verify_p05.sh"
# P03A/P04A/P05A/P06A cover source-content integrity, not Git/ZIP identity.
for phase in P03A P04A P05A P06A; do
  python3 "$P06_DOCSET_ROOT/tools/phase_scope_gate.py" --phase "$phase" \
    --require-implemented --code-root "$root" \
    >"$P06_LOG_ROOT/$phase-scope.log" 2>&1 || {
      echo "P06 BLOCKED: $phase implemented scope; see $P06_LOG_ROOT" >&2
      exit 1
    }
done
python3 "$P06_DOCSET_ROOT/tools/docsetctl.py" check --code-root "$root" \
  >"$P06_LOG_ROOT/docset-controller.log" 2>&1
python3 "$P06_DOCSET_ROOT/tools/check_contracts.py" >"$P06_LOG_ROOT/contracts.log" 2>&1
python3 -m unittest discover -s "$P06_DOCSET_ROOT/tools" -p 'test_*.py' \
  >"$P06_LOG_ROOT/docset-python.log" 2>&1
python3 -m unittest discover -s "$root/scripts/tests" -p 'test_*.py' \
  >"$P06_LOG_ROOT/source-python.log" 2>&1
python3 "$root/scripts/p06_release.py" --source-root "$root" --check-reproducible \
  >"$P06_LOG_ROOT/release-reproducible.log" 2>&1
# Fresh P06 outputs and wrappers are produced only by the trusted core.
(cd "$root/monorepo/beamcompass_core" &&
  mix beamcompass.scan "$root/fixtures/ledger_sample" --out "$P06_LOG_ROOT/p06-v1.json" &&
  mix beamcompass.export "$root/fixtures/ledger_sample" --schema 2 --project-id p06:matrix \
    --out "$P06_LOG_ROOT/p06-v2.json" &&
  P06_MATRIX_ROOT="$P06_LOG_ROOT" mix run -e '
    root = System.fetch_env!("P06_MATRIX_ROOT")
    {:ok, v1} = BeamCompass.load(Path.join(root, "p06-v1.json"))
    {:ok, v2} = JSON.decode(File.read!(Path.join(root, "p06-v2.json")))
    for {version, payload} <- [{"v1", v1}, {"v2", v2}] do
      {:ok, wrapped} = BeamCompass.wrap_compatibility(payload)
      File.write!(Path.join(root, "p06-envelope-" <> version <> ".json"), BeamCompass.Json.encode(wrapped) <> "\n")
    end') >"$P06_LOG_ROOT/p06-producers.log" 2>&1
python3 "$P06_DOCSET_ROOT/tools/p06_consumer_matrix.py" \
  --p06-v1 "$P06_LOG_ROOT/p06-v1.json" --p06-v2 "$P06_LOG_ROOT/p06-v2.json" \
  --p06-envelope-v1 "$P06_LOG_ROOT/p06-envelope-v1.json" \
  --p06-envelope-v2 "$P06_LOG_ROOT/p06-envelope-v2.json" \
  --out "$P06_LOG_ROOT/independent-consumer-matrix.json" \
  >"$P06_LOG_ROOT/independent-consumer-matrix.log" 2>&1
# Independent provenance is mandatory; never replace it with a first-party fixture.
: "${P06_EXTERNAL_PROJECT_ROOT:?P06 independent corpus path required}"
: "${P06_EXTERNAL_PROVENANCE:?P06 factual origin/revision/license required}"
python3 "$root/scripts/p06_corpus.py" --source-root "$root" \
  --external-project-root "$P06_EXTERNAL_PROJECT_ROOT" \
  --external-provenance "$P06_EXTERNAL_PROVENANCE" \
  --docset-root "$P06_DOCSET_ROOT" --out "$P06_LOG_ROOT/real-corpus" \
  >"$P06_LOG_ROOT/real-corpus.log" 2>&1
# Genuine old-v1/old-v2 and content-addressed archive corruption/recovery
# uses trusted core Mix ONLY, and measures restoration of previous valid data.
python3 "$root/scripts/p06_recovery.py" --source-root "$root" \
  --docset-root "$P06_DOCSET_ROOT" --out "$P06_RECOVERY_EVIDENCE" \
  >"$P06_LOG_ROOT/measured-recovery.log" 2>&1
# P06_OWNER_APPROVAL must be an independently recorded factual owner signoff.
python3 "$root/scripts/p06_release_gate.py" \
  --profile "$P06_LOG_ROOT/real-corpus/corpus-profile.json" \
  --recovery "$P06_RECOVERY_EVIDENCE" \
  --approval "$P06_OWNER_APPROVAL" --risks "$P06_DOCSET_ROOT/risks.md" \
  --out "$P06_LOG_ROOT/qualification.json" \
  >"$P06_LOG_ROOT/qualification.log" 2>&1 || {
    echo 'P06 RELEASE REFUSED: missing real signed-off measurements/recovery/closed critical risks' >&2
    exit 1
  }
echo "P06 full local qualification passed; artifacts: $P06_LOG_ROOT"
