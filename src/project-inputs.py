# SPDX-License-Identifier: MIT
"""Pin Nix producers and build Bun's native installation repository."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, os.environ['BUN_PURIFIER_PROJECT_INPUTS'])
import project_inputs

lockfile, state, references, refresh = sys.argv[1:]
file, state = Path(lockfile), Path(state)
previous = json.loads(file.read_text()).get('projectInputs', []) if file.exists() else []
requested = json.loads(references)
if requested is None:
    requested = [item['reference'] for item in previous]
pins = project_inputs.pin(requested, previous, refresh == 'true')
views = []
if pins:
    state.mkdir(parents=True, exist_ok=True)
    builds = json.loads(subprocess.check_output([
        'nix', 'build', '--impure', '--json', '--file',
        str(Path(os.environ['BUN_PURIFIER_LIB']) / 'interactive.nix'),
        '--argstr', 'nixpkgs', os.environ['BUN_PURIFIER_NIXPKGS'],
        '--argstr', 'src', str(file.parent), '--argstr', 'lockFile', str(file),
        '--argstr', 'projectInputs', json.dumps(pins),
        '--out-link', str(state / 'installation-repository'), 'npmInputs',
    ], text=True))
    outputs = {name: path for build in builds for name, path in build['outputs'].items()}
    views = [{'repository': outputs['out'], 'catalog': str(Path(outputs['metadata']) / 'catalog.json')}]
print(json.dumps({'projectInputs': pins, 'views': views}))
