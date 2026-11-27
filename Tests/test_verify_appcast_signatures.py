import base64
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("verify_appcast", ROOT / "scripts" / "verify-appcast-signatures.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

# RFC 8032, section 7.1, tests 1 and 2.
VECTORS = [
    ("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
]


def feed(body: bytes, signature: bytes, length=None) -> bytes:
    trailer = "<!-- sparkle-signatures:\nedSignature: %s\nlength: %d\n-->\n" % (
        base64.b64encode(signature).decode(), len(body) if length is None else length)
    return body + trailer.encode()


class Ed25519Tests(unittest.TestCase):
    def test_rfc8032_vectors_verify(self):
        for key, message, signature in VECTORS:
            self.assertTrue(verify.ed25519_verify(bytes.fromhex(key), bytes.fromhex(message), bytes.fromhex(signature)))

    def test_a_changed_message_or_signature_is_rejected(self):
        key, message, signature = (bytes.fromhex(part) for part in VECTORS[1])
        self.assertFalse(verify.ed25519_verify(key, message + b"x", signature))
        tampered = bytearray(signature)
        tampered[10] ^= 1
        self.assertFalse(verify.ed25519_verify(key, message, bytes(tampered)))
        self.assertFalse(verify.ed25519_verify(key, message, signature[:63]))


class FeedTests(unittest.TestCase):
    key_hex, message_hex, signature_hex = VECTORS[1]

    def key(self):
        return base64.b64encode(bytes.fromhex(self.key_hex)).decode()

    def test_valid_feed_verifies(self):
        data = feed(bytes.fromhex(self.message_hex), bytes.fromhex(self.signature_hex))
        self.assertEqual(verify.check_feed(data, self.key()), (True, "signature verifies"))

    def test_feed_edited_after_signing_is_reported_as_such(self):
        body = bytes.fromhex(self.message_hex) + b"<item>added by hand</item>"
        data = feed(body, bytes.fromhex(self.signature_hex), length=1)
        ok, reason = verify.check_feed(data, self.key())
        self.assertFalse(ok)
        self.assertIn("edited after signing", reason)

    def test_unsigned_feed_is_rejected(self):
        ok, reason = verify.check_feed(b"<rss></rss>", self.key())
        self.assertFalse(ok)
        self.assertIn("no sparkle-signatures trailer", reason)

    def test_signature_from_another_key_is_rejected(self):
        data = feed(bytes.fromhex(self.message_hex), bytes.fromhex(self.signature_hex))
        other = base64.b64encode(bytes.fromhex(VECTORS[0][0])).decode()
        self.assertFalse(verify.check_feed(data, other)[0])


if __name__ == "__main__":
    unittest.main()
