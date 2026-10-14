"""Reject unsafe/tampered archives and validate a real distributed app ZIP."""
import hashlib
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("app_update", ROOT / "Resources/app_update.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class ArchiveChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="modeldock-update-test-")
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def reject(self, entries, message):
        archive = self.root / "unsafe.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            for name, data, mode in entries:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                bundle.writestr(info, data)
        with self.assertRaisesRegex(ValueError, message):
            adapter.unpack(archive, self.root / "unpacked", hashlib.sha256(archive.read_bytes()).hexdigest(), archive.stat().st_size, "1.0.0")
        self.assertFalse((self.root / "unpacked").exists())

    def test_traversal(self):
        self.reject([("ModelDock.app/../../escape", b"bad", stat.S_IFREG)], "Unsafe")

    def test_absolute_path(self):
        self.reject([("/ModelDock.app/file", b"bad", stat.S_IFREG)], "Unsafe")

    def test_other_bundle(self):
        self.reject([("Other.app/file", b"bad", stat.S_IFREG)], "unexpected")

    def test_link_escape(self):
        self.reject([("ModelDock.app/link", b"../../escape", stat.S_IFLNK)], "escapes")

    def test_link_cycle(self):
        self.reject([("ModelDock.app/a", b"b", stat.S_IFLNK), ("ModelDock.app/b", b"a", stat.S_IFLNK)], "Cyclic")

    def test_link_writes(self):
        self.reject([("ModelDock.app/a", b"b", stat.S_IFLNK), ("ModelDock.app/a/file", b"bad", stat.S_IFREG)], "writes through")

    def test_duplicate(self):
        self.reject([("ModelDock.app/file", b"first", stat.S_IFREG), ("ModelDock.app/file", b"second", stat.S_IFREG)], "Duplicate")

    def test_device(self):
        self.reject([("ModelDock.app/device", b"bad", stat.S_IFCHR)], "Special")

    def test_checksum_tampering(self):
        archive = self.root / "tampered.zip"
        archive.write_bytes(b"not the release")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            adapter.unpack(archive, self.root / "unpacked", "0" * 64, archive.stat().st_size, "1.0.0")
        self.assertFalse((self.root / "unpacked").exists())

    def test_real_release(self):
        archive = ROOT / "dist/0.8.1/ModelDock-0.8.1-AppleSilicon.zip"
        if not archive.exists():
            self.skipTest("Historical local release ZIP not present")
        app = adapter.unpack(archive, self.root / "unpacked", hashlib.sha256(archive.read_bytes()).hexdigest(), archive.stat().st_size, "0.8.1")
        self.assertTrue((Path(app) / "Contents/MacOS/ModelManager").is_file())
        self.assertTrue((Path(app) / "Contents/Resources/PythonRuntime/bin/python3").is_file())


if __name__ == "__main__":
    unittest.main()
