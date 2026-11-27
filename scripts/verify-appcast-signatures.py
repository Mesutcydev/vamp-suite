#!/usr/bin/env python3
"""Check the EdDSA signature that Sparkle appends to an appcast.

Sparkle signs the feed text that comes before a trailing comment:

    </rss><!-- sparkle-signatures:
    edSignature: <base64>
    length: <bytes signed>
    -->

An app built with SURequireSignedFeed (Vamp Sync and Vamp Control) refuses a feed whose trailer is
missing or no longer matches, and editing a feed by hand after it was signed leaves exactly that state. Run this
before publishing so a stale signature stops the deploy instead of silently ending updates.

    scripts/verify-appcast-signatures.py                      # the repository defaults
    scripts/verify-appcast-signatures.py --require FEED:INFO.plist --warn FEED:INFO.plist

A `--require` feed that fails makes the exit status 1. A `--warn` feed only prints, for a feed whose
app does not demand a signed feed (none today). With no arguments both Mac feeds are required. The public key is the app's SUPublicEDKey. Verification is
done in plain Python (RFC 8032) so the deploy needs no extra packages.
"""
import argparse
import base64
import hashlib
import pathlib
import plistlib
import re
import sys

TRAILER = re.compile(
    rb"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: (\d+)\s*-->\s*$"
)

# RFC 8032 Ed25519, verification only.
_P = 2**255 - 19
_Q = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y):
    xx = (y * y - 1) * _inv(_D * y * y + 1)
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = x * _I % _P
    if x % 2 != 0:
        x = _P - x
    return x


_BY = 4 * _inv(5) % _P
_B = (_recover_x(_BY) % _P, _BY)


def _add(a, b):
    x1, y1 = a
    x2, y2 = b
    t = _D * x1 * x2 * y1 * y2
    return ((x1 * y2 + x2 * y1) * _inv(1 + t) % _P, (y1 * y2 + x1 * x2) * _inv(1 - t) % _P)


def _mul(point, scalar):
    result = (0, 1)
    while scalar:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _decode_point(data):
    if len(data) != 32:
        raise ValueError("bad point length")
    y = int.from_bytes(data, "little") & ((1 << 255) - 1)
    if y >= _P:
        raise ValueError("bad point")
    x = _recover_x(y)
    if (x & 1) != (data[31] >> 7):
        x = _P - x
    if (-x * x + y * y - 1 - _D * x * x * y * y) % _P != 0:
        raise ValueError("point is not on the curve")
    return (x, y)


def ed25519_verify(public_key, message, signature):
    if len(public_key) != 32 or len(signature) != 64:
        return False
    try:
        r_point = _decode_point(signature[:32])
        a_point = _decode_point(public_key)
    except ValueError:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _Q:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public_key + message).digest(), "little") % _Q
    return _mul(_B, s) == _add(r_point, _mul(a_point, h))


def check_feed(feed_bytes, public_key_b64):
    """Returns (ok, reason)."""
    match = TRAILER.search(feed_bytes)
    if not match:
        return False, "no sparkle-signatures trailer"
    body = feed_bytes[: match.start()]
    if int(match.group(2)) != len(body):
        return False, f"the signature covers {int(match.group(2))} bytes but the feed has {len(body)} before the trailer (edited after signing)"
    try:
        signature = base64.b64decode(match.group(1), validate=True)
        key = base64.b64decode(public_key_b64, validate=True)
    except ValueError:
        return False, "signature or public key is not base64"
    if not ed25519_verify(key, body, signature):
        return False, "the signature does not verify against the app's SUPublicEDKey"
    return True, "signature verifies"


def public_key_from(plist_path):
    with open(plist_path, "rb") as handle:
        return plistlib.load(handle)["SUPublicEDKey"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--require", action="append", default=None, metavar="FEED:INFO_PLIST")
    parser.add_argument("--warn", action="append", default=None, metavar="FEED:INFO_PLIST")
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent))
    args = parser.parse_args(argv)
    required = args.require if args.require is not None else [
        "docs/sync/appcast.xml:Configuration/VampMiniHost-Info.plist",
        "docs/control/appcast.xml:MacClient/Resources/MacClient-Info.plist",
    ]
    advisory = args.warn or []
    root = pathlib.Path(args.root)
    failed = False
    for entries, is_required in ((required, True), (advisory, False)):
        for entry in entries:
            feed, plist = entry.split(":", 1)
            feed_path = root / feed
            if not feed_path.exists():
                print(f"{'ERROR' if is_required else 'warning'}: {feed} does not exist")
                failed = failed or is_required
                continue
            try:
                key = public_key_from(root / plist)
            except (OSError, KeyError, ValueError) as error:
                print(f"{'ERROR' if is_required else 'warning'}: {feed}: cannot read SUPublicEDKey from {plist} ({error})")
                failed = failed or is_required
                continue
            ok, reason = check_feed(feed_path.read_bytes(), key)
            if ok:
                print(f"ok: {feed}: {reason}")
            else:
                print(f"{'ERROR' if is_required else 'warning'}: {feed}: {reason}")
                failed = failed or is_required
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
