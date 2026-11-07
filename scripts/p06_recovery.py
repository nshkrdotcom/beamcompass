#!/usr/bin/env python3
"""Real Mix-backed old-artifact, fault and read-only recovery measurements.

ALL Mix execution runs from trusted BeamCompass core; inspected Mix/config/
modules/macros/mutants are never executed. Prior valid bytes are kept intact,
mutants are separate temporary FILE DATA. No synthetic recovery passes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

V1 = 'handoffs/P03B-evidence/real-hold-ledger/baseline/v1.json'
V2 = 'handoffs/P05B-evidence/final-b2/snapshot.json'

# Mix.run -e evaluates only this FIXED trusted BeamCompass API harness, not
# any source/module/config under the scanned project tree.
CHECK = '''
input = System.fetch_env!("P06_INPUT")
expected = System.fetch_env!("P06_EXPECT")
kind = System.fetch_env!("P06_KIND")
result =
  with {:ok, bytes} <- File.read(input) do
    if kind == "v1" do
      with {:ok, value} <- BeamCompass.Model.Codec.decode(bytes),
           {:ok, wrapped} <- BeamCompass.wrap_compatibility(value),
           {:ok, ^value} <- BeamCompass.rehydrate_compatibility(wrapped) do
        {:ok, value}
      end
    else
      with {:ok, map} <- JSON.decode(bytes),
           {:ok, wrapped} <- BeamCompass.wrap_compatibility(map),
           {:ok, ^map} <- BeamCompass.rehydrate_compatibility(wrapped) do
        {:ok, map}
      end
    end
  end
case {expected, result} do
  {"accept", {:ok, _}} -> IO.puts("P06_ACCEPTED_EXACT_VERSION_LOSSLESS")
  {"refuse", {:error, _}} -> IO.puts("P06_REFUSED_BAD_VERSION_OR_DATA")
  _ -> raise "P06 wrong artifact acceptance: #{inspect(result)}"
end
'''
ARCHIVE_CREATE = '''
with {:ok, rec} <- BeamCompass.archive_source(System.fetch_env!("P06_SOURCE"),
  "p06:actual:recovery", System.fetch_env!("P06_ARCHIVE")) do
  IO.puts("P06_CREATED_ARCHIVE:" <> rec["content_id"])
else
  err -> raise "archive creation failed: #{inspect(err)}"
end
'''
ARCHIVE_READ = '''
result = BeamCompass.load_source_archive(System.fetch_env!("P06_ARCHIVE"),
  System.fetch_env!("P06_CONTENT_ID"))
case {System.fetch_env!("P06_EXPECT"), result} do
  {"accept", {:ok, bundle}} ->
    {:ok, _} = BeamCompass.Behavior.Archive.rehydrate(bundle)
    IO.puts("P06_ARCHIVE_REHYDRATED")
  {"refuse", {:error, _}} -> IO.puts("P06_ARCHIVE_CORRUPTION_REFUSED")
  _ -> raise "archive bad acceptance: #{inspect(result)}"
end
'''


def canonical(data):
    return json.dumps(data, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def mutant_versions(v1_bytes, v2_bytes):
    v1_data = json.loads(v1_bytes)
    v2_data = json.loads(v2_bytes)
    future1 = dict(v1_data, schema_version=99)
    future2 = dict(v2_data, schema_version=99)
    trust = json.loads(v2_bytes)
    trust['evidence'][0]['mode'] = 'observed'
    trust['snapshot_id'] = digest(canonical({k: v for k, v in trust.items() if k != 'snapshot_id'}))
    return [('v1-invalid-json', 'v1', b'not-json-at-all'),
            ('v1-future', 'v1', canonical(future1) + b'\n'),
            ('v2-future', 'v2', canonical(future2) + b'\n'),
            ('v2-rehashed-observed', 'v2', canonical(trust) + b'\n'),
            ('v2-broken-json', 'v2', b'{')]


def invoke(cmd, cwd, env, expected_exit=0, label=None, timeout=120):
    t0 = time.monotonic_ns()
    try:
        r = subprocess.run(cmd, cwd=cwd, env=dict(os.environ, **env), text=True,
                           capture_output=True, timeout=timeout)
        exit_code, stdout, stderr = r.returncode, r.stdout, r.stderr
    except FileNotFoundError as exc:
        exit_code, stdout, stderr = 127, '', 'unavailable: ' + str(exc)
    except subprocess.TimeoutExpired as exc:
        exit_code, stdout, stderr = 124, '', 'timeout: ' + str(exc)
    record = {'case': label, 'command': cmd, 'cwd': str(cwd), 'environment_keys': sorted(env),
              'exit_code': exit_code, 'expected_exit': expected_exit,
              'stdout': stdout, 'stderr': stderr,
              'elapsed_ms': round((time.monotonic_ns() - t0) / 1_000_000, 3)}
    record['matched'] = exit_code == expected_exit
    return record


def run(source_root, docset_root, out):
    core = source_root / 'monorepo/beamcompass_core'
    v1_bytes = (docset_root / V1).read_bytes()
    v2_bytes = (docset_root / V2).read_bytes()
    report = {'format': 'beamcompass.p06-actual-recovery', 'schema_version': 1,
              'status': 'blocked', 'previous_data_unchanged': False, 'recovery_ms': None,
              'command': ['mix', 'run', '-e', CHECK],
              'cwd': str(core), 'cases': [],
              'prior_content_sha256': {'old_v1': digest(v1_bytes), 'old_v2': digest(v2_bytes)},
              'limitation': 'Mix tests trusted core; this is no OS sandbox, publisher signature or owner approval'}
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='p06-actual-recovery-') as tmp:
        temp = Path(tmp)
        v1 = temp / 'prior-v1.json'
        v2 = temp / 'prior-v2.json'
        v1.write_bytes(v1_bytes)
        v2.write_bytes(v2_bytes)
        ok = True

        def record(cmd, env, label, expected_exit=0):
            nonlocal ok
            row = invoke(cmd, core, env, expected_exit, label)
            report['cases'].append(row)
            if not row['matched']:
                ok = False
            return row

        for name, kind, path in [('old-v1-real', 'v1', v1), ('old-v2-real', 'v2', v2)]:
            row = record(['mix','run','-e',CHECK], {'P06_INPUT':str(path),'P06_KIND':kind,
                                                    'P06_EXPECT':'accept'}, name)
            if not row['matched']:
                break
        if ok:
            for name, kind, blob in mutant_versions(v1_bytes, v2_bytes):
                path = temp / (name + '.json')
                path.write_bytes(blob)
                row = record(['mix','run','-e',CHECK], {'P06_INPUT':str(path),'P06_KIND':kind,
                                                        'P06_EXPECT':'refuse'}, name)
                if not row['matched']:
                    break
        if ok:
            archive_root = temp / 'archive-valid'
            row = record(['mix','run','-e',ARCHIVE_CREATE], {'P06_SOURCE':str(source_root / 'fixtures/ledger_sample'),
                                                            'P06_ARCHIVE':str(archive_root)}, 'archive-real-source')
            match = re.search(r'P06_CREATED_ARCHIVE:([0-9a-f]{64})', row['stdout'])
            if not match:
                ok = False
            if ok:
                content_id = match.group(1)
                parent = archive_root / 'v1' / content_id[:2]
                path = parent / (content_id + '.json')
                valid = path.read_bytes()
                row = record(['mix','run','-e',ARCHIVE_READ], {'P06_ARCHIVE':str(archive_root),
                                                               'P06_CONTENT_ID':content_id,'P06_EXPECT':'accept'},
                             'valid-immutable-archive')
                if row['matched']:
                    bad_root = temp / 'archive-corrupt'
                    bad_path = bad_root / 'v1' / content_id[:2] / (content_id + '.json')
                    bad_path.parent.mkdir(parents=True)
                    bad_path.write_bytes(valid.replace(b'"schema_version":1',b'"schema_version":99',1))
                    if bad_path.read_bytes() == valid:
                        bad_path.write_bytes(b'{invalid-json')
                    record(['mix','run','-e',ARCHIVE_READ], {'P06_ARCHIVE':str(bad_root),
                                                             'P06_CONTENT_ID':content_id,'P06_EXPECT':'refuse'},
                           'corrupt-archive-refusal')
                    bad_path.unlink()
                    secret = temp / 'secret-unmodified'
                    secret.write_bytes(b'keep-private-prior')
                    bad_path.symlink_to(secret)
                    record(['mix','run','-e',ARCHIVE_READ], {'P06_ARCHIVE':str(bad_root),
                                                             'P06_CONTENT_ID':content_id,'P06_EXPECT':'refuse'},
                           'symlink-archive-refusal')
                    report['archive_content_sha256'] = digest(valid)
                    ok = ok and path.read_bytes() == valid and secret.read_bytes() == b'keep-private-prior'
        if ok:
            # Inject genuine failing trusted CLI source acquisition before its
            # output writer can execute; the previous v1 bytes stay untouched.
            bad_root = temp / 'nonexistent-target'
            row = record(['mix','beamcompass.scan',str(bad_root),'--out',str(v1)], {},
                         'source-fault-writer-does-not-destroy-prior', expected_exit=1)
            if row['matched']:
                begun = time.monotonic_ns()
                recovery = record(['mix','run','-e',CHECK], {'P06_INPUT':str(v1),'P06_KIND':'v1',
                                                            'P06_EXPECT':'accept'}, 'post-fault-old-v1-recovery')
                report['recovery_ms'] = round((time.monotonic_ns()-begun)/1_000_000,3)
                if not recovery['matched']:
                    ok = False
        report['previous_data_unchanged'] = (
            v1.read_bytes() == v1_bytes and v2.read_bytes() == v2_bytes and
            (docset_root / V1).read_bytes() == v1_bytes and (docset_root / V2).read_bytes() == v2_bytes)
        report['status'] = 'passed' if ok and report['previous_data_unchanged'] and report['recovery_ms'] is not None else 'blocked'
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('source-root', 'docset-root', 'out'):
        p.add_argument('--' + key, required=True, type=Path)
    args = p.parse_args()
    try:
        report = run(args.source_root.absolute(), args.docset_root.absolute(), args.out.absolute())
        print(json.dumps({'status':report['status'],'cases':len(report['cases']),
                          'previous_data_unchanged':report['previous_data_unchanged'],
                          'recovery_ms':report['recovery_ms']},sort_keys=True))
        return 0 if report['status'] == 'passed' else 1
    except (OSError,KeyError,ValueError,TypeError) as exc:
        print('P06 REAL RECOVERY BLOCKED: '+str(exc),file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
