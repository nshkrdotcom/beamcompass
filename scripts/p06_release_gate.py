#!/usr/bin/env python3
"""Fail-closed independent P06 release decision, never Grand approval policy.

Inputs MUST be real trusted-export profiles, recovery evidence, explicitly
owner-approved numeric SLOs and the actual risk register. Source caps are not
release budgets; hashes are only integrity, not publisher authenticity.
"""
import argparse
import json
from pathlib import Path
import re
import sys

REQUIRED = ('max_wall_ms', 'max_rss_bytes', 'max_source_files', 'max_recovery_ms')


def evaluate(profile, recovery, approval, risks):
    blockers = []
    if profile.get('acceptance_passed') is not True or len(profile.get('corpora', [])) < 3:
        blockers.append('real_exporter_corpus_measurements_absent')
    if profile.get('source_mode') != 'source':
        blockers.append('source_only_mode_not_proven')
    corpora = profile.get('corpora', [])
    for item in corpora:
        runs = item.get('export_runs', [])
        checks = item.get('consumer_runs', [])
        if len(runs) < 2 or len(checks) < 2 or not item.get('deterministic_export_digest'):
            blockers.append('unverified_corpus:' + str(item.get('id', '?')))
        for run in runs:
            if run.get('exit_code') != 0 or not isinstance(run.get('elapsed_ms'), (int, float)) or \
               not isinstance(run.get('peak_rss_bytes_sampled'), int) or run.get('rss_samples', 0) < 1:
                blockers.append('resource_profile_unmeasured:' + str(item.get('id', '?')))
        if any(check.get('exit_code') != 0 for check in checks):
            blockers.append('consumer_incompatibility:' + str(item.get('id', '?')))
    if not isinstance(recovery, dict) or recovery.get('status') != 'passed' or \
       recovery.get('previous_data_unchanged') is not True or \
       not isinstance(recovery.get('recovery_ms'), (int, float)) or \
       not isinstance(recovery.get('command'), list) or not recovery.get('command'):
        blockers.append('real_fault_recovery_evidence_absent')
    if not isinstance(approval, dict) or approval.get('approved') is not True or \
       not isinstance(approval.get('owner'), str) or not approval['owner'].strip() or \
       approval.get('synthetic') is True or \
       any(type(approval.get(k)) not in (int, float) or approval[k] <= 0 for k in REQUIRED):
        blockers.append('owner_approved_numeric_budgets_absent')
    if not isinstance(risks, str) or not risks.strip():
        blockers.append('risk_register_absent')
    else:
        # The source risk register has both Markdown tables and narrative notes.
        # Its initial critical/active entry is open until an owner closes it.
        rows = [re.split(r'\s*\|\s*', line.strip().strip('|')) for line in risks.splitlines() if line.startswith('| RISK-')]
        for row in rows:
            if len(row) > 5 and any(re.search(r'\b(critical|high)\b', s, re.I) for s in row[1:3]) and \
               row[-1].strip().lower() not in ('closed', 'resolved'):
                blockers.append('open_high_severity:' + row[0].strip())
    if not blockers and len({x['id'] for x in corpora}) != len(corpora):
        blockers.append('duplicate_corpus_identity')
    if not blockers:
        for item in corpora:
            for run in item['export_runs']:
                if run['elapsed_ms'] > approval['max_wall_ms']:
                    blockers.append('wall_budget_exceeded:' + item['id'])
                if run['peak_rss_bytes_sampled'] > approval['max_rss_bytes']:
                    blockers.append('rss_budget_exceeded:' + item['id'])
            if item['source_files'] > approval['max_source_files']:
                blockers.append('file_count_budget_exceeded:' + item['id'])
        if recovery['recovery_ms'] > approval['max_recovery_ms']:
            blockers.append('recovery_budget_exceeded')
    return {'format': 'beamcompass.p06-release-decision', 'schema_version': 1,
            'status': 'passed' if not blockers else 'refused', 'eligible': not blockers,
            'blockers': sorted(set(blockers)), 'approval_owner': approval.get('owner') if isinstance(approval, dict) else None,
            'note': 'P06 actual source-only release criteria; no Grand approval or proof guarantee'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('profile', 'recovery', 'approval', 'risks', 'out'):
        p.add_argument('--' + name, required=True, type=Path)
    args = p.parse_args()
    try:
        profile = json.loads(args.profile.read_text())
        recovery = json.loads(args.recovery.read_text())
        approval = json.loads(args.approval.read_text())
        result = evaluate(profile, recovery, approval, args.risks.read_text())
    except (OSError, ValueError, TypeError) as e:
        result = {'format': 'beamcompass.p06-release-decision', 'schema_version': 1,
                  'status': 'refused', 'eligible': False, 'blockers': ['unavailable_or_malformed_gate_input:' + str(e)]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, sort_keys=True))
    return 0 if result['eligible'] else 1


if __name__ == '__main__':
    sys.exit(main())
