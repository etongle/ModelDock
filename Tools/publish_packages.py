"""Mirror verified native macOS release files to a GitHub Packages OCI artifact."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import quote

ARTIFACT_TYPE = 'application/vnd.modeldock.macos-release.v1'


def gh_json(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def validate_payload(payload, version):
    manifest = json.loads((payload / 'release.json').read_text())
    if manifest.get('version') != version or manifest.get('appBundle') != 'ModelDock.app' or manifest.get('architecture') != 'arm64':
        raise ValueError('Release version, application or architecture does not match')
    expected = {f'ModelDock-{version}-AppleSilicon.{suffix}' for suffix in ['dmg', 'zip']}
    artifacts = manifest.get('artifacts', [])
    if len(artifacts) != 2 or {item.get('name') for item in artifacts} != expected:
        raise ValueError('Release must contain exactly the expected DMG and ZIP')
    checksums = {}
    for line in (payload / 'SHA256SUMS.txt').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (ModelDock-[0-9]+\.[0-9]+\.[0-9]+-AppleSilicon\.(?:dmg|zip))', line)
        if not match or match[2] in checksums:
            raise ValueError('Invalid or duplicate checksum entry')
        checksums[match[2]] = match[1]
    if set(checksums) != expected:
        raise ValueError('Checksums do not describe this release')
    for item in artifacts:
        path = payload / item['name']
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item.get('bytes'):
            raise ValueError('Release file is missing or has the wrong size')
        sha = digest(path)
        if sha != item.get('sha256') or sha != checksums[item['name']]:
            raise ValueError('Release SHA-256 verification failed')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', 'etongle/ModelDock'))
    parser.add_argument('--tag', required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--registry-config', type=Path)
    parser.add_argument('--oras', default='oras')
    parser.add_argument('--local-release', type=Path, help='Use local release files for an OCI layout check')
    parser.add_argument('--oci-layout', type=Path, help='Validate a local OCI round trip without publishing')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args.tag):
        parser.error('Expected owner/repository and a vMAJOR.MINOR.PATCH release tag')
    if bool(args.local_release) != bool(args.oci_layout):
        parser.error('Local release input requires a local OCI layout')
    version = args.tag[1:]
    root = args.work_dir.resolve()
    payload = root / 'payload'
    payload.mkdir(parents=True, exist_ok=True)
    if any(payload.iterdir()):
        raise ValueError('Use a fresh work directory')
    names = [f'ModelDock-{version}-AppleSilicon.dmg', f'ModelDock-{version}-AppleSilicon.zip', 'INSTALL.txt', 'SHA256SUMS.txt', 'release.json']
    source = 'https://github.com/' + args.repository
    if args.local_release:
        for name in names:
            shutil.copy2(args.local_release / name, payload / name)
        project = Path(__file__).resolve().parents[1]
        for name in ['LICENSE', 'LICENSE-NOTICE.txt']:
            shutil.copy2(project / name, payload / name)
        revision, created, promote_latest = 'local-verification', '1970-01-01T00:00:00Z', False
    else:
        release = gh_json(f'repos/{args.repository}/releases/tags/{quote(args.tag, safe="")}')
        if release.get('draft') or release.get('tag_name') != args.tag:
            raise ValueError('A published release is required')
        assets = {item['name']: item for item in release['assets']}
        if any(name not in assets or assets[name]['state'] != 'uploaded' for name in names):
            raise ValueError('The release is missing completed installation assets')
        command = ['gh', 'release', 'download', args.tag, '--repo', args.repository, '--dir', str(payload)]
        for name in names:
            command += ['--pattern', name]
        subprocess.run(command, check=True)
        for name in names:
            server_digest = assets[name].get('digest')
            if (payload / name).stat().st_size != assets[name]['size'] or (server_digest and server_digest != 'sha256:' + digest(payload / name)):
                raise ValueError('Downloaded asset differs from GitHub release metadata')
        for name in ['LICENSE', 'LICENSE-NOTICE.txt']:
            content = gh_json(f'repos/{args.repository}/contents/{name}?ref={quote(args.tag, safe="")}')
            if content.get('encoding') != 'base64' or content.get('type') != 'file':
                raise ValueError('Release license file is unavailable')
            (payload / name).write_bytes(base64.b64decode(content['content']))
        revision = gh_json(f'repos/{args.repository}/commits/{args.tag}')['sha']
        created = release['published_at']
        promote_latest = not release.get('prerelease') and gh_json(f'repos/{args.repository}/releases/latest')['tag_name'] == args.tag
    manifest = validate_payload(payload, version)
    names += ['LICENSE', 'LICENSE-NOTICE.txt']
    artifact_files = {name: digest(payload / name) for name in names}
    reference = 'ghcr.io/' + args.repository.lower() + ':' + version
    if args.oci_layout:
        reference = str(args.oci_layout.resolve()) + ':' + version
    common = ['--registry-config', str(args.registry_config.resolve())] if args.registry_config else []
    local = ['--oci-layout'] if args.oci_layout else []
    annotation = {
        'org.opencontainers.image.source': source,
        'org.opencontainers.image.url': source + '/releases/tag/' + args.tag,
        'org.opencontainers.image.description': 'Apple Silicon macOS installation files. Extract with ORAS, then open the DMG or ZIP. PolyForm Noncommercial 1.0.0.',
        'org.opencontainers.image.version': version,
        'org.opencontainers.image.revision': revision,
        'org.opencontainers.image.created': created,
        'org.opencontainers.image.licenses': 'PolyForm-Noncommercial-1.0.0',
        'io.modeldock.minimum-macos': manifest['minimumMacOS'],
        'io.modeldock.architecture': manifest['architecture'],
    }
    command = [args.oras, 'push', *common, *local, '--artifact-type', ARTIFACT_TYPE, '--export-manifest', str(root / 'oci-manifest.json')]
    for key, value in annotation.items():
        command += ['--annotation', key + '=' + value]
    command.append(reference)
    media = {'.dmg': 'application/x-apple-diskimage', '.zip': 'application/zip', '.json': 'application/json'}
    command += [name + ':' + media.get(Path(name).suffix, 'text/plain') for name in names]
    subprocess.run(command, cwd=payload, check=True)
    artifact_digest = subprocess.check_output([args.oras, 'resolve', *common, *local, reference], text=True).strip()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', artifact_digest):
        raise ValueError('Registry returned an invalid manifest digest')
    pulled = root / 'roundtrip'
    subprocess.run([args.oras, 'pull', *common, *local, reference, '--output', str(pulled)], check=True)
    if {path.name for path in pulled.iterdir()} != set(names) or any(digest(pulled / name) != value for name, value in artifact_files.items()):
        raise ValueError('Registry round-trip files do not match the verified release')
    promote_latest = promote_latest and gh_json(f'repos/{args.repository}/releases/latest')['tag_name'] == args.tag
    if promote_latest:
        subprocess.run([args.oras, 'tag', *common, reference, 'latest'], check=True)
    package = None
    if not args.oci_layout:
        try:
            owner, name = args.repository.lower().split('/')
            package = gh_json(f'users/{owner}/packages/container/{name}')
            if (package.get('repository') or {}).get('full_name', '').lower() != args.repository.lower():
                raise ValueError('Published package is not linked to the expected repository')
        except subprocess.CalledProcessError:
            pass  # Registry round trip remains authoritative if API metadata is unavailable.
    report = {'result': 'passed', 'reference': reference, 'digest': artifact_digest, 'release': args.tag, 'sourceRevision': revision,
              'files': artifact_files, 'roundTripVerified': True, 'latestUpdated': promote_latest,
              'packageUrl': package.get('html_url') if package else None, 'visibility': package.get('visibility') if package else 'unknown'}
    (root / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write(f'## ModelDock package {version}\n\n`{reference}`\n\nManifest: `{artifact_digest}`\n\nAll seven release/license files passed a registry download and SHA-256 comparison.\n\n')
            if report['packageUrl']:
                output.write(f"[Package settings and versions]({report['packageUrl']})\n\n")
            if report['visibility'] != 'public':
                output.write('First publication defaults to private. In Package settings, choose Change visibility → Public to allow anonymous downloads.\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
