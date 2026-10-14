"""ModelDock's adapter for the official Strata Apple Silicon source build.

Engine installations are immutable. Model data and per-service configs live
outside the source tree; preparation never starts a model implicitly.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import uuid

REPOSITORY = 'https://github.com/Niko1221/Strata.git'
VARIANTS = ('Q2_0', 'IQ3_XXS', 'IQ3_S', 'UD-Q4_K_XL', 'UD-Q5_K_XL', 'UD-Q6_K_XL')


def emit(stage, message):
    print('[ModelDock Strata] ' + stage + ': ' + message, flush=True)


def run(args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def read_config(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size > 1_000_000:
        raise ValueError('Invalid Strata configuration')
    value = json.loads(path.read_text(encoding='utf-8-sig'))
    if value.get('backend') != 'metal' or not isinstance(value.get('args'), list):
        raise ValueError('Select an official Strata Metal configuration')
    if not all(isinstance(arg, str) and '\0' not in arg for arg in value['args']):
        raise ValueError('Invalid engine arguments')
    return value


def option(args, name):
    indexes = [i for i, arg in enumerate(args) if arg == name]
    if len(indexes) > 1 or indexes and indexes[0] + 1 >= len(args):
        raise ValueError('Duplicate or incomplete option: ' + name)
    return args[indexes[0] + 1] if indexes else None


def set_option(args, name, value):
    option(args, name)
    if name in args:
        i = args.index(name)
        del args[i:i + 2]
    if value is not None:
        args.extend([name, str(value)])


def component_paths(config):
    args = config['args']
    paths = {name: option(args, flag) for name, flag in
             [('weights', '--native'), ('ngram', '--ple-gguf'), ('pack', '--pack')]}
    paths['tokenizer'] = config.get('tokenizer')
    if option(args, '--mtp'):
        paths['draft'] = str(Path(option(args, '--mtp')).parent / 'mtp-q2_0.gguf')
    if config.get('vision'):
        paths['vision'] = config['vision'].get('mmproj')
    return paths


def validate_components(config):
    paths = component_paths(config)
    for name in ('weights', 'ngram', 'pack', 'tokenizer'):
        if not isinstance(paths[name], str) or not Path(paths[name]).is_absolute():
            raise ValueError('Missing or relative component: ' + name)
    for name, value in paths.items():
        if value and not Path(value).exists():
            raise ValueError('Missing component ' + name + ': ' + value)
    if not (Path(paths['tokenizer']) / 'vocab.json').is_file():
        raise ValueError('Tokenizer vocab.json is missing')
    if not (Path(paths['pack']) / 'native_experts.txt').is_file():
        raise ValueError('Strata pack native_experts.txt is missing')
    return paths


def preflight():
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise ValueError('Strata Metal requires an Apple Silicon Mac')
    version = tuple(int(v) for v in platform.mac_ver()[0].split('.')[:2])
    if version < (15, 0):
        raise ValueError('Strata Metal requires macOS 15 or newer')
    run(['/usr/bin/xcrun', '--find', 'clang'])
    if sys.version_info < (3, 10):
        raise ValueError('Strata requires Python 3.10 or newer')


def private_environment(source, destination, python_runtime=None):
    python = sys.executable
    if python_runtime:
        original = Path(python_runtime).resolve()
        if not (original / 'bin/python3').is_file():
            raise ValueError('Portable Python runtime is incomplete')
        # A venv points at its base interpreter. Retain our own base so replacing
        # ModelDock.app cannot invalidate an already-installed Strata runtime.
        portable = Path(destination) / 'python-runtime'
        shutil.copytree(original, portable, symlinks=True)
        python = portable / 'bin/python3'
    run([python, '-m', 'venv', Path(source) / '.venv'])
    return Path(source) / '.venv/bin/python'


def install(args):
    preflight()
    if not re.fullmatch('[a-f0-9]{40}', args.revision):
        raise ValueError('A fixed official source revision is required')
    destination = Path(args.destination)
    if not destination.is_absolute() or destination.exists():
        raise ValueError('Choose a new absolute installation directory')
    destination.mkdir(parents=True)
    source = destination / 'source'
    emit('source', 'Fetching official revision ' + args.revision)
    archive = destination / 'source.tar.gz'
    address = 'https://codeload.github.com/Niko1221/Strata/tar.gz/' + args.revision
    for attempt in range(3):
        try:
            with urllib.request.urlopen(address, timeout=60) as response, archive.open('wb') as output:
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > 1_000_000_000:
                        raise ValueError('Official source archive exceeds the installation limit')
                    output.write(block)
                    if size % (16 * 1024 * 1024) < len(block):
                        emit('source', str(size // 1024 // 1024) + ' MiB downloaded')
            break
        except (OSError, TimeoutError):
            if attempt == 2:
                raise
            emit('source', 'Retrying interrupted official source download')
            time.sleep(attempt + 1)
    top = 'Strata-' + args.revision
    with tarfile.open(archive) as packed:
        entries = packed.getmembers()
        if len(entries) > 100_000:
            raise ValueError('Too many source archive entries')
        for member in entries:
            parts = Path(member.name).parts
            if not parts or parts[0] != top or '..' in parts or not (member.isfile() or member.isdir()):
                raise ValueError('Unsafe source archive entry: ' + member.name)
        if hasattr(tarfile, 'data_filter'):
            packed.extractall(destination, filter='data')
        else:
            packed.extractall(destination)  # Every member above is a checked regular file/directory.
    (destination / top).rename(source)
    actual = args.revision
    emit('environment', 'Creating a private Python environment')
    python = private_environment(source, destination, args.python_runtime)
    run([python, '-m', 'pip', '--isolated', 'install', '--disable-pip-version-check',
         '--index-url', 'https://pypi.org/simple', '-r', source / 'requirements.txt'])
    emit('building', 'Compiling Strata Metal; no model weights are downloaded')
    # --update returns immediately after building, before the model download.
    run([python, '-u', source / 'setup.py', '--yes', '--update', '--no-browser',
         '--data-dir', destination / 'build-data'], cwd=source)
    binary = source / 'build-metal/strata'
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError('Metal build did not produce an executable')
    emit('vision build', 'Compiling the vision encoder; no projection weights are downloaded')
    run([python, '-u', '-c', 'import sys;sys.path.insert(0,sys.argv[1]);import setup as S;'
         'import metal.setup_mac as M;M.build_vision(S.get_llama_cpp())', str(source)], cwd=source)
    # Validate the server contract without loading a 125B model.
    run([python, source / 'serve/server.py', '--help'], cwd=source)
    shutil.copy2(__file__, destination / 'modeldock_strata.py')
    wrapper = destination / 'modeldock-strata'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(python)) + ' -u ' +
                       shlex.quote(str(destination / 'modeldock_strata.py')) +
                       ' serve --runtime ' + shlex.quote(str(source)) + ' "$@"\n')
    wrapper.chmod(0o755)
    version = re.search(r'project\(strata VERSION ([\d.]+)', (source / 'CMakeLists.txt').read_text()).group(1)
    atomic_json(destination / 'modeldock-runtime.json',
                {'repository': REPOSITORY, 'revision': actual, 'version': version,
                 'sourceArchiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                 'backend': 'metal', 'engine': str(binary), 'source': str(source)})
    emit('verified', 'Metal engine and server validated; models remain separate')


def upstream(runtime):
    runtime = Path(runtime).resolve()
    if not (runtime / 'metal/setup_mac.py').is_file():
        raise ValueError('Strata runtime is incomplete')
    sys.path.insert(0, str(runtime))
    import setup as setup_module
    import metal.setup_mac as mac
    return runtime, setup_module, mac


def catalogue(args):
    runtime, setup_module, mac = upstream(args.runtime)
    variants = []
    for name in VARIANTS:
        family = mac.MAC_MODELS[name].get('family', 'qwen')
        template = setup_module.FAMILIES[family]['hf'].format(q=name)
        match = re.match(r'https://huggingface.co/([^/]+/[^/]+)/resolve/([^/]+)/(.*)', template)
        if not match:
            raise ValueError('Unsupported official download source')
        variants.append({'name': name, 'repository': match[1], 'revision': match[2],
                         'files': [match[3] + filename for filename in mac.model_shard_names(name)],
                         'downloadGB': setup_module.MODELS[name]['download_gb']})
    print(json.dumps({'variants': variants}))


def prepare(args):
    runtime = Path(args.runtime).resolve()
    preflight()
    data = Path(args.data_dir)
    if not data.is_absolute() or (data / 'modeldock-strata.json').exists():
        raise ValueError('A completed assembly is immutable; use a new model directory')
    gguf = Path(args.gguf_dir).resolve()
    if not gguf.is_dir():
        raise ValueError('Select the folder containing every downloaded model shard')
    request = {'runtime': str(runtime), 'model': args.model, 'gguf': str(gguf), 'vision': args.vision, 'context': args.context}
    marker = data / 'modeldock-preparation.json'
    if data.exists():
        if not marker.is_file() or json.loads(marker.read_text()) != request:
            raise ValueError('This incomplete preparation belongs to a different model or runtime')
    else:
        data.mkdir(parents=True)
        atomic_json(marker, request)
    python = runtime / '.venv/bin/python'
    emit('preparing', args.model + '; tokenizer, MTP and vision use the official setup')
    # Configs are written inside the immutable runtime by upstream. Redirect only
    # the config publication into this model's separate directory in a child.
    adapter = '''import sys, pathlib, json
sys.path.insert(0, sys.argv[1])
import setup as S
import metal.setup_mac as M
root = pathlib.Path(sys.argv[2])
original = S.write_config
def write(path, cfg):
    if cfg.get('backend') == 'metal':
        cfg['log'] = str(root / 'engine.log')
        (root / 'strata.json').write_text(json.dumps(cfg, indent=2))
    else:
        original(path, cfg)
S.write_config = write
S.write_run_script = lambda *a, **k: root / 'strata.json'
raise SystemExit(M.main(sys.argv[3:]))
'''
    command = [python, '-u', '-c', adapter, str(runtime), str(data), '--yes', '--setup', '--no-start',
               '--no-browser', '--model', args.model, '--context', str(args.context),
               '--port', '8095', '--host', '127.0.0.1', '--vision', args.vision,
               '--data-dir', str(data), '--gguf-dir', str(gguf)]
    run(command, cwd=runtime)
    config = read_config(data / 'strata.json')
    paths = validate_components(config)
    files = {}
    for role, value in paths.items():
        if not value:
            continue
        path = Path(value)
        if path.is_dir():
            for child in path.rglob('*'):
                if child.is_file() and not child.is_symlink():
                    files[role + '/' + child.relative_to(path).as_posix()] = {'path': str(child), 'bytes': child.stat().st_size}
        else:
            files[role] = {'path': str(path), 'bytes': path.stat().st_size}
    atomic_json(data / 'modeldock-strata.json', {'schema': 1, 'model': args.model,
                'name': config.get('model_name', args.model), 'config': str(data / 'strata.json'),
                'backend': 'metal', 'files': files, 'vision': bool(config.get('vision')),
                'sourceRevision': json.loads((runtime.parent / 'modeldock-runtime.json').read_text())['revision']})
    emit('ready', 'Prepared model registered at ' + str(data))


def service_config(original, runtime, port, context, mode, draft, speculation):
    value = json.loads(json.dumps(original))
    validate_components(value)
    runtime = Path(runtime).resolve()
    value['exe'] = str(runtime / 'build-metal/strata')
    value['cwd'] = str(runtime)
    value['host'] = '127.0.0.1'
    value['port'] = port
    value['open_browser'] = False
    # Imported upstream configs are data, not permission to run hooks or MCP.
    for key in ('before_load', 'mcp', 'mcp_servers', 'mcp_config', 'api_key', 'replicas', 'gpu', 'lib_dirs'):
        value.pop(key, None)
    value['env'] = {key: val for key, val in value.get('env', {}).items()
                    if key in ('STRATA_METAL_STREAM', 'STRATA_HC_Q8') and isinstance(val, str)}
    set_option(value['args'], '--max-context', context)
    if draft == 'off':
        set_option(value['args'], '--mtp', None)
        set_option(value['args'], '--spec', 1)
    elif draft == 'on' and not option(value['args'], '--mtp'):
        raise ValueError('This assembly has no MTP draft; prepare it with the official setup first')
    elif speculation:
        set_option(value['args'], '--spec', speculation)
    if mode == 'text':
        value.pop('vision', None)
        value['args'] = [arg for arg in value['args'] if arg != '--vision']
    elif mode == 'multimodal' and not value.get('vision'):
        raise ValueError('This assembly has no vision component; prepare a vision-enabled assembly')
    if value.get('vision'):
        value['vision']['exe'] = str(runtime / 'build-vision/bin/strata-vision')
        if not Path(value['vision']['exe']).is_file():
            raise ValueError('Current runtime has no vision encoder; prepare a vision-enabled model')
    return value


def serve(args):
    if not 1024 <= args.port <= 65535 or not 1024 <= args.context <= 262144:
        raise ValueError('Invalid port or context')
    runtime = Path(args.runtime).resolve()
    if args.config is None:
        raise ValueError('Use --config with a prepared Strata model')
    value = service_config(read_config(args.config), runtime, args.port, args.context,
                           args.mode, args.draft, args.speculation)
    # Each start receives an immutable config. Original model/settings stay intact.
    folder = Path(args.instance_dir)
    if not folder.is_absolute():
        raise ValueError('A separate service directory is required')
    folder.mkdir(parents=True, exist_ok=True)
    config = folder / ('strata-' + uuid.uuid4().hex + '.json')
    value['log'] = str(config.with_suffix('.engine.log'))
    atomic_json(config, value)
    emit('loading', 'Loading main weights and n-gram table')
    paths = component_paths(value)
    print('[ModelDock Strata components] ' + json.dumps(paths), flush=True)
    python = runtime / '.venv/bin/python'
    os.execv(str(python), [str(python), '-u', str(runtime / 'serve/server.py'),
                          '--engine', 'strata', '--config', str(config),
                          '--host', '127.0.0.1', '--port', str(args.port)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    task = sub.add_parser('install')
    task.add_argument('--python-runtime')
    task.add_argument('--revision', required=True)
    task.add_argument('--destination', required=True)
    task = sub.add_parser('catalogue')
    task.add_argument('--runtime', required=True)
    task = sub.add_parser('prepare')
    task.add_argument('--runtime', required=True)
    task.add_argument('--model', choices=VARIANTS, required=True)
    task.add_argument('--data-dir', required=True)
    task.add_argument('--gguf-dir', required=True)
    task.add_argument('--vision', choices=('yes', 'no'), default='no')
    task.add_argument('--context', type=int, default=32768)
    task = sub.add_parser('serve')
    task.add_argument('--runtime', required=True)
    task.add_argument('--config')
    task.add_argument('--instance-dir', required=True)
    task.add_argument('--port', type=int, default=8095)
    task.add_argument('--context', type=int, default=32768)
    task.add_argument('--mode', choices=('automatic', 'text', 'multimodal'), default='automatic')
    task.add_argument('--draft', choices=('automatic', 'on', 'off'), default='automatic')
    task.add_argument('--speculation', type=int, choices=range(1, 5))
    args = parser.parse_args()
    globals()[{'catalogue':'catalogue', 'install':'install', 'prepare':'prepare', 'serve':'serve'}[args.command]](args)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('[ModelDock Strata] error: ' + str(error), file=sys.stderr, flush=True)
        raise SystemExit(1)
