#!/usr/bin/env bash

# Generate CycloneDX release metadata for current Vamp artifacts.
# Generates SBOM metadata for current Vamp Suite artifacts.

set -euo pipefail

[[ $# -eq 6 ]] || {
  printf 'Usage: %s <artifact> <vamp-terminal|vamp-host|vamp-terminal-host|vamp-mini-host|vamp-stream-ios|vamp-control-ios|vamp-control-macos> <version> <build> <commit> <output>\n' "$0" >&2
  exit 64
}

artifact="$1"
component="$2"
version="$3"
build="$4"
commit="$5"
output="$6"

[[ -f "$artifact" ]] || { printf 'Artifact not found: %s\n' "$artifact" >&2; exit 1; }
case "$component" in
  vamp-terminal|vamp-host|vamp-terminal-host|vamp-mini-host|vamp-stream-ios|vamp-control-ios|vamp-control-macos) ;;
  *) printf 'Unsupported Vamp component: %s\n' "$component" >&2; exit 64 ;;
esac

sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
serial_seed="$(printf '%s:%s' "$commit" "$(basename "$artifact")" | shasum -a 256 | awk '{print $1}')"
serial="${serial_seed:0:8}-${serial_seed:8:4}-${serial_seed:12:4}-${serial_seed:16:4}-${serial_seed:20:12}"

ARTIFACT="$artifact" COMPONENT="$component" VERSION="$version" BUILD="$build" \
  COMMIT="$commit" OUTPUT="$output" SHA="$sha" SERIAL="$serial" \
  python3 - <<'PY'
import datetime
import json
import os

component = os.environ["COMPONENT"]
bundle_ids = {
    "vamp-terminal": "com.mesutcy.remotedesktop.terminal",
    "vamp-host": "com.mesutcy.remotedesktop.host",
    "vamp-terminal-host": "com.mesutcy.remotedesktop.terminalhost",
    "vamp-mini-host": "com.mesutcy.remotedesktop.minhost",
    "vamp-stream-ios": "com.mesutcy.remotedesktop.stream",
    "vamp-control-ios": "com.mesutcy.remotedesktop.ios",
    "vamp-control-macos": "com.mesutcy.remotedesktop.macclient",
}
app_names = {
    "vamp-terminal": "Vamp Terminal",
    "vamp-host": "Vamp Host",
    "vamp-terminal-host": "Vamp Terminal Host",
    "vamp-mini-host": "Vamp Sync",
    "vamp-stream-ios": "Vamp Stream",
    "vamp-control-ios": "Vamp Control iOS",
    "vamp-control-macos": "Vamp Control macOS",
}
signatures = {
    "vamp-terminal": "unsigned",
    "vamp-host": "ad-hoc",
    "vamp-terminal-host": "ad-hoc",
    "vamp-mini-host": "ad-hoc",
    "vamp-stream-ios": "unsigned",
    "vamp-control-ios": "unsigned",
    "vamp-control-macos": "ad-hoc",
}

artifact = os.environ["ARTIFACT"]
version = os.environ["VERSION"]
build = os.environ["BUILD"]
commit = os.environ["COMMIT"]
sha = os.environ["SHA"]
app_name = app_names[component]
bundle_id = bundle_ids[component]
application_ref = f"pkg:generic/{bundle_id}@{version}?build={build}"

dependencies = [
    {
        "type": "library",
        "group": "xiph.org",
        "name": "opus",
        "version": "1.6.1",
        "bom-ref": "pkg:generic/opus@1.6.1",
        "licenses": [{"license": {"id": "BSD-3-Clause"}}],
    }
]
if component in {"vamp-terminal", "vamp-stream-ios"}:
    dependencies.append(
        {
            "type": "library",
            "group": "github.com/migueldeicaza",
            "name": "SwiftTerm",
            "version": "1.20.0",
            "bom-ref": "pkg:github/migueldeicaza/SwiftTerm@1.20.0",
            "licenses": [{"license": {"id": "MIT"}}],
        }
    )

if component == "vamp-mini-host":
    dependencies.append({
        "type": "library", "group": "github.com/sparkle-project",
        "name": "Sparkle", "version": "2.10.0",
        "bom-ref": "pkg:github/sparkle-project/Sparkle@2.10.0",
        "licenses": [{"license": {"id": "MIT"}}],
    })

payload = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{os.environ['SERIAL']}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "tools": {"components": [{"type": "application", "name": "generate-vamp-sbom.sh"}]},
        "component": {
            "type": "application",
            "name": app_name,
            "version": f"{version}+{build}",
            "bom-ref": application_ref,
            "hashes": [{"alg": "SHA-256", "content": sha}],
            "externalReferences": [
                {"type": "vcs", "url": f"https://github.com/Mesutcydev/vamp-suite/tree/{commit}"},
                {"type": "website", "url": "https://thevamp.app/"},
            ],
        },
        "properties": [
            {"name": "vamp:sourceCommit", "value": commit},
            {"name": "vamp:codeSignature", "value": os.environ.get("VAMP_ARTIFACT_SIGNATURE", signatures[component])},
            {"name": "vamp:appleNotarized", "value": os.environ.get("VAMP_ARTIFACT_NOTARIZED", "false")},
        ],
    },
    "components": dependencies,
    "dependencies": [{"ref": application_ref, "dependsOn": [item["bom-ref"] for item in dependencies]}],
}

with open(os.environ["OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
