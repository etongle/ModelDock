"""Reject altered, cross-version and path-traversal release payloads before upload."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

project = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publish_packages', project / 'Tools/publish_packages.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PackagePayloadChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.payload = Path(self.temporary.name)
        entries = []
        for suffix in ['dmg', 'zip']:
            name = f'ModelDock-0.9.5-AppleSilicon.{suffix}'
            (self.payload / name).write_bytes(b'complete verified release fixture')
            entries.append({'name': name, 'bytes': (self.payload / name).stat().st_size, 'sha256': publisher.digest(self.payload / name)})
        self.manifest = {'version': '0.9.5', 'appBundle': 'ModelDock.app', 'architecture': 'arm64', 'artifacts': entries}
        self.save()
        (self.payload / 'SHA256SUMS.txt').write_text(''.join(row['sha256'] + '  ' + row['name'] + '\n' for row in entries))

    def tearDown(self):
        self.temporary.cleanup()

    def save(self):
        (self.payload / 'release.json').write_text(json.dumps(self.manifest))

    def test_valid_payload(self):
        self.assertEqual(publisher.validate_payload(self.payload, '0.9.5')['version'], '0.9.5')

    def test_same_size_tampering(self):
        (self.payload / self.manifest['artifacts'][0]['name']).write_bytes(b'X' * self.manifest['artifacts'][0]['bytes'])
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.9.5')

    def test_cross_version(self):
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.8.3')

    def test_traversal(self):
        self.manifest['artifacts'][0]['name'] = '../outside.dmg'; self.save()
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.9.5')

    def test_duplicate_artifact(self):
        self.manifest['artifacts'].append(self.manifest['artifacts'][0]); self.save()
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.9.5')

    def test_conflicting_checksum(self):
        p = self.payload / 'SHA256SUMS.txt'; p.write_text(p.read_text().replace(self.manifest['artifacts'][0]['sha256'], '0' * 64))
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.9.5')

    def test_symlink(self):
        p = self.payload / self.manifest['artifacts'][0]['name']; other = self.payload / 'outside'; shutil.move(p, other); p.symlink_to(other)
        with self.assertRaises(ValueError): publisher.validate_payload(self.payload, '0.9.5')


if __name__ == '__main__':
    unittest.main()
