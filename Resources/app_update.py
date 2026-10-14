"""Audit and extract a ModelDock release ZIP; never replaces the running app."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import zipfile


def unpack(archive, destination, digest, size, version):
    archive, destination = Path(archive), Path(destination)
    if not re.fullmatch(r"[a-f0-9]{64}", digest) or archive.stat().st_size != size:
        raise ValueError("Release size or SHA-256 metadata is invalid")
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != digest:
        raise ValueError("Release SHA-256 mismatch; existing application is preserved")
    if destination.exists():
        raise ValueError("Extraction directory must be new")
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if not 1 <= len(entries) <= 30000 or sum(e.file_size for e in entries) > 1_500_000_000:
            raise ValueError("Release archive is too large")
        names, links = set(), {}
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            if not parts or name.startswith("/") or "\\" in name or ".." in parts or "\x00" in name:
                raise ValueError("Unsafe release archive path")
            if parts[0] not in ("ModelDock.app", "__MACOSX"):
                raise ValueError("Release contains an unexpected top-level item")
            if parts[0] == "__MACOSX":
                if any(not p.startswith("._") and p != "ModelDock.app" and p not in ("__MACOSX", "Contents", "Resources", "MacOS") for p in parts):
                    # ditto may mirror arbitrary runtime subdirectories in metadata.
                    if not parts[-1].startswith("._") and not entry.is_dir():
                        raise ValueError("Unexpected ZIP metadata")
            if name.rstrip("/") in names:
                raise ValueError("Duplicate release archive entry")
            names.add(name.rstrip("/"))
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise ValueError("Special files are not allowed")
            if stat.S_ISLNK(mode):
                if parts[0] != "ModelDock.app" or entry.file_size > 4096:
                    raise ValueError("Unsafe archive link")
                target = bundle.read(entry).decode("utf-8")
                if not target or target.startswith("/") or "\\" in target:
                    raise ValueError("Absolute archive link")
                normalized = os.path.normpath(str(PurePosixPath(name).parent / target))
                if not normalized.startswith("ModelDock.app/"):
                    raise ValueError("Archive link escapes application")
                links[name] = normalized
        # Resolve chains as well as direct links, before any extraction occurs.
        def resolve(name, visiting):
            for prefix in sorted(links, key=len, reverse=True):
                if name == prefix or name.startswith(prefix + "/"):
                    if prefix in visiting:
                        raise ValueError("Cyclic archive links")
                    return resolve(links[prefix] + name[len(prefix):], visiting | {prefix})
            return name
        for name in names:
            if not resolve(name, set()).startswith("ModelDock.app/") and name != "ModelDock.app" and not name.startswith("__MACOSX/") and name != "__MACOSX":
                raise ValueError("Archive link escapes application")
            # Files nested below a link can redirect ditto writes: refuse them.
            if any(name.startswith(link + "/") for link in links):
                raise ValueError("Archive writes through a symbolic link")
    destination.mkdir(mode=0o700, parents=True)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], check=True)
    app = destination / "ModelDock.app"
    for base, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            item = Path(base) / name
            if item.is_symlink() and not item.resolve().is_relative_to(app.resolve()):
                raise ValueError("Extracted link escapes application")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "local.null.ModelManager" or info.get("CFBundleShortVersionString") != version or info.get("CFBundleExecutable") != "ModelManager":
        raise ValueError("Release application identity or version does not match")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/ModelManager")], text=True).split()
    if "arm64" not in architecture:
        raise ValueError("Release does not support Apple Silicon")
    minimum = [int(v) for v in info.get("LSMinimumSystemVersion", "999").split(".")]
    import platform
    current = [int(v) for v in platform.mac_ver()[0].split(".")]
    if (minimum + [0] * 3)[:3] > (current + [0] * 3)[:3]:
        raise ValueError("Release needs a newer macOS version")
    return str(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(json.dumps({"application": unpack(args.archive, args.destination, args.sha256, args.bytes, args.version)}))


if __name__ == "__main__":
    main()
