#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/server/sync/refresh_jwks.sh"
fixtures="$repo_root/test/server/fixtures"

"$script" --validate "$fixtures/jwks_public.json"

if "$script" --validate "$fixtures/jwks_private.json"; then
  printf 'private signing material was accepted\n' >&2
  exit 1
fi

if "$script" --validate "$fixtures/jwks_empty.json"; then
  printf 'an empty key set was accepted\n' >&2
  exit 1
fi

python3 - "$script" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cloud = 'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1'
vps = 'https://sb.zangetsu.online/auth/v1'
source = lambda issuer: {'issuer': issuer, 'url': issuer + '/.well-known/jwks.json'}
key = lambda kid: {'kty': 'EC', 'crv': 'P-256', 'kid': kid, 'x': 'test-x', 'y': 'test-y', 'alg': 'ES256'}
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    destination = root / 'jwks.json'
    config = root / 'jwks-sources.json'
    script = root / 'refresh.sh'
    script.write_text(Path(sys.argv[1]).read_text().replace('/etc/zangetsu-sync/jwks.json', str(destination)).replace('/etc/zangetsu-sync/jwks-sources.json', str(config)))
    tools = root / 'bin'
    tools.mkdir()
    (tools / 'curl').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert '--location' not in args and '-L' not in args
assert args[0] == '--disable'
url = args[-1]
with open(os.environ['RESPONSES']) as f: response = json.load(f)[url]
with open(os.environ['FETCHES'], 'a') as f: f.write(url + '\\n')
if response == 'failure': sys.exit(22)
pathlib.Path(args[args.index('--output') + 1]).write_text(json.dumps(response))
print(os.environ.get('HTTP_STATUS', '200'), end='')
''')
    for command in ['chown', 'systemctl']:
        (tools / command).write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ACTIONS"\n')
    for command in tools.iterdir(): command.chmod(0o755)
    responses = root / 'responses.json'
    fetches = root / 'fetches'
    actions = root / 'actions'
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], RESPONSES=str(responses), FETCHES=str(fetches), ACTIONS=str(actions))
    def run(sources, payloads, success, status='200'):
        if sources is None:
            config.unlink(missing_ok=True)
        else:
            config.write_text(json.dumps(sources))
        destination.write_text('existing-good-output')
        fetches.write_text('')
        actions.write_text('')
        responses.write_text(json.dumps(payloads))
        result = subprocess.run(['bash', str(script)], env=dict(env, HTTP_STATUS=status), capture_output=True, text=True)
        assert (result.returncode == 0) == success, (sources, payloads, result.returncode, result.stderr)
        if not success:
            assert destination.read_text() == 'existing-good-output'
            assert not actions.read_text(), actions.read_text()
        else:
            assert destination.stat().st_mode & 0o777 == 0o640
            assert 'root:sync_authenticator' in actions.read_text()
            assert '--signal=SIGUSR2 zangetsu-sync-stage.service' in actions.read_text()
        assert not list(root.glob('jwks.json.tmp.*'))
        return json.loads(destination.read_text()) if success else None
    payloads = {source(cloud)['url']: {'keys': [key('cloud')]}, source(vps)['url']: {'keys': [key('vps')]}}
    merged = run([source(cloud), source(vps)], payloads, True)
    assert [(k['kid'], k['issuer']) for k in merged['keys']] == [('cloud', cloud), ('vps', vps)]
    assert len(fetches.read_text().splitlines()) == 2
    assert run(None, payloads, True)['keys'][0]['issuer'] == cloud
    assert fetches.read_text().splitlines() == [source(cloud)['url']]
    assert run([source(vps)], payloads, True)['keys'][0]['issuer'] == vps
    assert fetches.read_text().splitlines() == [source(vps)['url']]
    # An unchanged successful refresh still reloads, without replacing the file.
    before = destination.stat().st_ino
    actions.write_text('')
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
    assert result.returncode == 0 and destination.stat().st_ino == before
    assert 'root:sync_authenticator' not in actions.read_text()
    assert '--signal=SIGUSR2' in actions.read_text()
    for sources in [[], [source('https://evil.invalid/auth/v1')], [dict(source(cloud), url=source(vps)['url'])], [source(cloud), source(cloud)], [dict(source(cloud), url=source(cloud)['url'] + '?extra=1')], {}]:
        run(sources, payloads, False)
        assert not fetches.read_text()
    for invalid in [{'keys': []}, {'keys': [key('duplicate'), key('duplicate')]}, {'keys': [dict(key('private'), d='secret')]}, {'keys': [dict(key('private'), oth=[])]}, {'keys': [dict(key('wrong'), issuer=cloud)]}, {'keys': 'malformed'}, 'failure']:
        run([source(cloud), source(vps)], dict(payloads, **{source(vps)['url']: invalid}), False)
    run([source(cloud), source(vps)], dict(payloads, **{source(vps)['url']: {'keys': [key('cloud')]}}), False)
    run([source(cloud)], payloads, False, status='302')
    config.write_text('{invalid json')
    destination.write_text('existing-good-output')
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
    assert result.returncode != 0 and destination.read_text() == 'existing-good-output'
    config.write_text(json.dumps([source(cloud)]) + '\n' + json.dumps([source(vps)]))
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
    assert result.returncode != 0 and destination.read_text() == 'existing-good-output'
    duplicate = root / 'duplicate.json'
    duplicate.write_text(json.dumps({'keys': [key('same'), key('same')]}))
    assert subprocess.run(['bash', str(script), '--validate', str(duplicate)], capture_output=True).returncode != 0
    duplicate.write_text(json.dumps({'keys': []}) + '\n' + json.dumps({'keys': [key('valid')]}))
    assert subprocess.run(['bash', str(script), '--validate', str(duplicate)], capture_output=True).returncode != 0
print('JWKS source/merge/failure tests passed')
PY
