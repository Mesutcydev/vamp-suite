#!/usr/bin/env python3
"""Verify the unsigned Stream IPA layout and release manifest before upload."""
import hashlib
import json
import plistlib
from pathlib import Path, PurePosixPath
import struct
import sys
import zipfile


def verify(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), "Duplicate ZIP entries"
        assert archive.testzip() is None, "Corrupt ZIP member"
        root = "Payload/Vamp Stream.app/"
        for name in names:
            parts = PurePosixPath(name).parts
            assert not name.startswith("/") and ".." not in parts, "Unsafe ZIP path"
            assert name == "Payload/" or name.startswith(root), f"Unexpected IPA entry: {name}"
            assert "_CodeSignature" not in parts and parts[-1] != "embedded.mobileprovision", "IPA must be unsigned"
        info = plistlib.loads(archive.read(root + "Info.plist"))
        assert info["CFBundleIdentifier"] == "com.mesutcy.remotedesktop.stream"
        assert info["CFBundlePackageType"] == "APPL"
        assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
        executable = archive.read(root + info["CFBundleExecutable"])
        magic, cpu, _, file_type, count, _, _, _ = struct.unpack_from("<8I", executable)
        assert magic == 0xFEEDFACF and cpu == 0x100000C and file_type == 2, "Expected arm64 device executable"
        offset, device = 32, False
        for _ in range(count):
            command, size = struct.unpack_from("<II", executable, offset)
            assert size >= 8 and offset + size <= len(executable)
            if command == 0x32:
                device = struct.unpack_from("<I", executable, offset + 8)[0] == 2
            offset += size
        assert device, "Executable must target iOS, not iOS Simulator"
    manifest = json.loads(Path(str(path) + ".manifest.json").read_text())
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert manifest["sha256"] == digest
    assert manifest["sizeBytes"] == path.stat().st_size
    assert manifest["artifact"] == path.name
    assert manifest["version"] == info["CFBundleShortVersionString"]
    assert manifest["build"] == info["CFBundleVersion"]
    assert manifest["bundleIdentifier"] == info["CFBundleIdentifier"]
    assert manifest["signature"] == "unsigned" and manifest["requiresResigning"]
    assert Path(str(path) + ".sha256").read_text().split()[0] == digest
    print(f"Verified {path.name}: Payload/Vamp Stream.app, iOS arm64, unsigned, manifest and SHA-256 match")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
