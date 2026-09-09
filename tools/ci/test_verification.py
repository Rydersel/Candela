#!/usr/bin/env python3
"""Regression checks for selecting suites and rejecting incomplete CI results."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from verification import classify, verify

SCRIPT = Path(__file__).with_name('verification.py')


class ScopeTests(unittest.TestCase):
    def test_documentation_needs_no_expensive_suite(self):
        self.assertEqual(classify(['README.md', 'docs/guide/checkup.md', '.github/assets/icon.png']), (False, False))

    def test_site_includes_its_markdown_and_configuration(self):
        self.assertEqual(classify(['site/src/content/guides/oled.md', 'site/package-lock.json']), (False, True))

    def test_app_and_unknown_files_require_app_verification(self):
        for name in ['Candela/New.swift', 'CandelaAppTests/New.swift', 'CandelaKit/Package.swift', 'project.yml', 'Makefile', 'new-build-config']:
            with self.subTest(name=name):
                self.assertEqual(classify([name]), (True, False))

    def test_workflow_or_selection_changes_exercise_both_suites(self):
        for name in ['.github/workflows/site.yml', '.github/workflows/build-and-test.yml', 'tools/ci/verification.py']:
            with self.subTest(name=name):
                self.assertEqual(classify([name]), (True, True))

    def test_mixed_changes_require_both(self):
        self.assertEqual(classify(['Candela/New.swift', 'site/src/App.tsx']), (True, True))

    def test_no_changes_can_skip_both(self):
        self.assertEqual(classify([]), (False, False))

    def test_cli_counts_removed_side_of_a_rename(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
            git('init', '-q')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            (root / 'Old.swift').write_text('same content\n')
            git('add', '.')
            git('commit', '-qm', 'initial')
            (root / 'Old.swift').rename(root / 'README.md')
            git('add', '-A')
            git('commit', '-qm', 'rename')
            result = subprocess.run(['python3', str(SCRIPT), 'scope'], cwd=root,
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request'},
                                    capture_output=True, text=True, check=True)
            self.assertIn('app=true', result.stdout)
            self.assertIn('site=false', result.stdout)

    def test_merge_commit_covers_all_pr_commits(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
            git('init', '-q', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            (root / 'README.md').write_text('base\n')
            git('add', '.')
            git('commit', '-qm', 'initial')
            git('checkout', '-qb', 'change')
            (root / 'New.swift').write_text('source\n')
            git('add', '.')
            git('commit', '-qm', 'source first')
            (root / 'README.md').write_text('updated docs\n')
            git('add', '.')
            git('commit', '-qm', 'docs last')
            git('checkout', '-q', 'main')
            git('merge', '--no-ff', '-qm', 'PR merge', 'change')
            result = subprocess.run(['python3', str(SCRIPT), 'scope'], cwd=root,
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request'},
                                    capture_output=True, text=True, check=True)
            self.assertIn('app=true', result.stdout)

    def test_missing_git_parent_fails_instead_of_skipping(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(['python3', str(SCRIPT), 'scope'], cwd=folder,
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request'},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('app=false', result.stdout)

    def test_manual_or_push_run_requires_both(self):
        for event in ['workflow_dispatch', 'push']:
            result = subprocess.run(['python3', str(SCRIPT), 'scope'],
                                    env={**os.environ, 'GITHUB_EVENT_NAME': event},
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, 'app=true\nsite=true\n')


class GateTests(unittest.TestCase):
    def needs(self, required='true', result='success', scope='success', suite='app'):
        names = ['test', 'app-build', 'release-build'] if suite == 'app' else ['site']
        return {'scope': {'result': scope, 'outputs': {suite: required}},
                **{name: {'result': result} for name in names}}

    def test_completed_suites_pass(self):
        for suite in ['app', 'site']:
            verify(self.needs(suite=suite), suite)

    def test_explicitly_unneeded_suites_may_skip(self):
        for suite in ['app', 'site']:
            verify(self.needs(required='false', result='skipped', suite=suite), suite)

    def test_every_required_job_must_succeed(self):
        for job in ['test', 'app-build', 'release-build']:
            for result in ['failure', 'cancelled', 'skipped', '']:
                with self.subTest(job=job, result=result):
                    needs = self.needs()
                    needs[job]['result'] = result
                    with self.assertRaises(ValueError):
                        verify(needs, 'app')

    def test_failed_or_missing_scope_cannot_pass(self):
        for result in ['failure', 'cancelled', 'skipped', '']:
            with self.assertRaises(ValueError):
                verify(self.needs(scope=result), 'app')
        with self.assertRaises(ValueError):
            verify({}, 'app')

    def test_invalid_scope_output_or_missing_jobs_cannot_pass(self):
        for required in ['', 'maybe', None]:
            with self.assertRaises(ValueError):
                verify(self.needs(required=required), 'app')
        needs = self.needs()
        del needs['test']
        with self.assertRaises(ValueError):
            verify(needs, 'app')

    def test_site_failure_is_not_hidden(self):
        with self.assertRaises(ValueError):
            verify(self.needs(result='failure', suite='site'), 'site')

    def test_cli_reports_failure(self):
        result = subprocess.run(['python3', str(SCRIPT), 'gate', 'app'],
                                env={**os.environ, 'NEEDS_JSON': json.dumps(self.needs(result='failure'))},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
