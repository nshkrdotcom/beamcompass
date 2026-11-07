"""Explicit fixture-only tests, never imply owner approval of production targets."""
import sys
import json
import subprocess
import tempfile
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import p06_release_gate as gate


def samples():
    run = {'exit_code': 0, 'elapsed_ms': 2, 'peak_rss_bytes_sampled': 200, 'rss_samples': 1}
    corpus = lambda ident: {'id': ident, 'source_files': 2, 'export_runs': [run, run],
                            'consumer_runs': [{'exit_code': 0}, {'exit_code': 0}],
                            'deterministic_export_digest': 'fixture-only'}
    profile = {'acceptance_passed': True, 'source_mode': 'source', 'corpora': [corpus(x) for x in ('a', 'b', 'c')]}
    recovery = {'status': 'passed', 'previous_data_unchanged': True, 'recovery_ms': 1,
                'command': ['synthetic-fixture-only']}
    owner = {'approved': True, 'owner': 'fictional-test-owner', 'max_wall_ms': 10,
             'max_rss_bytes': 500, 'max_source_files': 10, 'max_recovery_ms': 10}
    return profile, recovery, owner


class P06ReleaseGateTests(unittest.TestCase):
    def test_fixture_only_approved_and_measured_path(self):
        profile, recovery, owner = samples()
        self.assertTrue(gate.evaluate(profile, recovery, owner, '| ID | Risk | Impact | Mitigation | Owner | Status |')['eligible'])

    def test_missing_owner_approval_refused(self):
        profile, recovery, _ = samples()
        result = gate.evaluate(profile, recovery, {}, 'risk register\n')
        self.assertIn('owner_approved_numeric_budgets_absent', result['blockers'])

    def test_critical_active_risk_refused_even_if_budgets_good(self):
        profile, recovery, owner = samples()
        risks = '| RISK-001 | False confidence | Critical false confidence | Mitigate | owner | Active |'
        self.assertIn('open_high_severity:RISK-001', gate.evaluate(profile, recovery, owner, risks)['blockers'])

    def test_missing_real_rss_or_recovery_refused(self):
        profile, recovery, owner = samples()
        profile['corpora'][0]['export_runs'][0]['peak_rss_bytes_sampled'] = None
        recovery['previous_data_unchanged'] = False
        blockers = gate.evaluate(profile, recovery, owner, 'risk register\n')['blockers']
        self.assertTrue(any('resource_profile_unmeasured:' in b for b in blockers))
        self.assertIn('real_fault_recovery_evidence_absent', blockers)

    def test_observed_budget_breach_refused(self):
        profile, recovery, owner = samples()
        owner['max_wall_ms'] = 1
        self.assertIn('wall_budget_exceeded:a', gate.evaluate(profile, recovery, owner, 'risk register\n')['blockers'])

    def test_missing_approval_reports_open_risk_in_real_cli(self):
        profile, recovery, _ = samples()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'profile.json').write_text(json.dumps(profile))
            (root / 'recovery.json').write_text(json.dumps(recovery))
            (root / 'risks.md').write_text(
                '| RISK-001 | False confidence | Critical | Mitigate | owner | Active |')
            result = subprocess.run([sys.executable, str(Path(gate.__file__)),
                '--profile', str(root / 'profile.json'), '--recovery', str(root / 'recovery.json'),
                '--approval', str(root / 'absent.json'), '--risks', str(root / 'risks.md'),
                '--out', str(root / 'decision.json')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            decision = json.loads((root / 'decision.json').read_text())
            self.assertFalse(decision['eligible'])
            self.assertIn('owner_approved_numeric_budgets_absent', decision['blockers'])
            self.assertIn('open_high_severity:RISK-001', decision['blockers'])


if __name__ == '__main__':
    unittest.main()
