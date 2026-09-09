#!/usr/bin/env python3
"""Select relevant PR suites and validate their final results."""
import json
import os
import subprocess
import sys


def classify(paths):
    app = site = False
    for path in paths:
        if path.startswith(('.github/workflows/', 'tools/ci/')):
            app = site = True
        elif path.startswith('site/'):
            site = True
        elif (path.endswith('.md') or path.startswith(('docs/', '.github/assets/', '.github/ISSUE_TEMPLATE/'))
              or path == 'LICENSE'):
            continue
        else:
            # Unknown paths require verification rather than disappearing from an allow-list.
            app = True
    return app, site


def verify(needs, suite):
    scope = needs.get('scope', {})
    required = scope.get('outputs', {}).get(suite)
    if scope.get('result') != 'success' or required not in ('true', 'false'):
        raise ValueError('Suite selection did not finish successfully.')
    jobs = {'app': ('test', 'app-build', 'release-build'), 'site': ('site',)}[suite]
    expected = 'success' if required == 'true' else 'skipped'
    for job in jobs:
        result = needs.get(job, {}).get('result')
        if result != expected:
            raise ValueError(f'{job}: expected {expected}, received {result or "no result"}.')


def main():
    if sys.argv[1:] == ['scope']:
        if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
            # Checkout supplies the PR merge commit and its parents at depth two.
            # Disable rename detection so moving source into docs still runs its suite.
            result = subprocess.run(['git', 'diff', '--no-renames', '--name-only', '-z', 'HEAD^1', 'HEAD'],
                                    check=True, capture_output=True)
            paths = [path.decode('utf-8', errors='surrogateescape') for path in result.stdout.split(b'\0') if path]
            app, site = classify(paths)
        else:
            # Push workflows already filter paths; manual runs always exercise their suite.
            app = site = True
        print(f'app={str(app).lower()}\nsite={str(site).lower()}')
    elif len(sys.argv) == 3 and sys.argv[1] == 'gate' and sys.argv[2] in ('app', 'site'):
        verify(json.loads(os.environ['NEEDS_JSON']), sys.argv[2])
        print(f'{sys.argv[2]} verification passed.')
    else:
        raise ValueError('Usage: verification.py scope | gate app | gate site')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Verification failed: {error}', file=sys.stderr)
        sys.exit(1)
