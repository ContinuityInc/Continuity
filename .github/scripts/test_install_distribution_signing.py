#!/usr/bin/env python3
"""Offline checks for the TestFlight signing helper. No network, no API key."""

import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("install_distribution_signing.py")
spec = importlib.util.spec_from_file_location("install_distribution_signing", SCRIPT)
assert spec and spec.loader
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningHelperTests(unittest.TestCase):
    def test_es256_signature_round_trips_through_openssl(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "key.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                check=True,
                capture_output=True,
            )
            message = b"continuity-signing"
            raw = signing.sign_es256(key, message)
            self.assertEqual(len(raw), 64)
            header = signing.b64url(b'{"alg":"ES256"}')
            self.assertNotIn("=", header)
            token = signing.make_token("KEYID", "ISSUER", key, now=1_700_000_000)
            signing_input, sig_b64 = token.rsplit(".", 1)
            padded = sig_b64 + "=" * (-len(sig_b64) % 4)
            import base64

            raw_sig = base64.urlsafe_b64decode(padded)
            self.assertEqual(len(raw_sig), 64)
            der = raw_to_der(raw_sig)
            der_path = Path(tmp) / "sig.der"
            public = Path(tmp) / "public.pem"
            der_path.write_bytes(der)
            subprocess.run(
                ["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)],
                check=True,
                capture_output=True,
            )
            verified = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(der_path)],
                input=signing_input.encode(),
                capture_output=True,
                check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr.decode())

    def test_profile_accepts_only_the_app_group_and_our_certificate(self):
        der = b"\x30\x03cert"
        plist = {
            "Entitlements": {"com.apple.security.application-groups": [signing.APP_GROUP]},
            "DeveloperCertificates": [der],
        }
        self.assertTrue(signing.usable_profile(plist, signing.APP_GROUP, der))
        self.assertFalse(signing.usable_profile(plist, signing.APP_GROUP, b"other"))
        plist["Entitlements"]["com.apple.security.application-groups"] = ["group.other"]
        self.assertFalse(signing.profile_has_group(plist, signing.APP_GROUP))

    def test_cms_profile_decodes_to_its_entitlements(self):
        plist = {
            "Name": "ContinuityCIStore",
            "UUID": "00000000-0000-0000-0000-000000000001",
            "Entitlements": {"com.apple.security.application-groups": [signing.APP_GROUP]},
        }
        with tempfile.TemporaryDirectory() as tmp:
            xml = Path(tmp) / "profile.plist"
            key = Path(tmp) / "key.pem"
            cert = Path(tmp) / "cert.pem"
            signed = Path(tmp) / "profile.mobileprovision"
            with xml.open("wb") as handle:
                plistlib.dump(plist, handle, fmt=plistlib.FMT_XML)
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-keyout",
                    str(key),
                    "-out",
                    str(cert),
                    "-days",
                    "1",
                    "-nodes",
                    "-subj",
                    "/CN=test",
                ],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [
                    "openssl",
                    "cms",
                    "-sign",
                    "-nodetach",
                    "-binary",
                    "-signer",
                    str(cert),
                    "-inkey",
                    str(key),
                    "-in",
                    str(xml),
                    "-outform",
                    "DER",
                    "-out",
                    str(signed),
                ],
                check=True,
                capture_output=True,
            )
            decoded = signing.decode_provision_plist(signed.read_bytes())
        self.assertEqual(decoded["Name"], "ContinuityCIStore")
        self.assertTrue(signing.profile_has_group(decoded, signing.APP_GROUP))

    def test_release_xcconfig_and_export_options_name_both_targets(self):
        text = signing.release_xcconfig("ContinuityCIStore")
        self.assertIn("CODE_SIGN_STYLE = Manual\n", text)
        self.assertIn("CODE_SIGN_IDENTITY = Apple Distribution\n", text)
        self.assertIn("PROVISIONING_PROFILE_SPECIFIER = ContinuityCIStore\n", text)
        self.assertNotIn('"', text)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ExportOptions.plist"
            signing.write_export_options(
                path,
                {
                    "com.sanylax.continuity": "ContinuityCIStore",
                    "com.sanylax.continuity.share": "ContinuityShareCIStore",
                },
            )
            with path.open("rb") as handle:
                options = plistlib.load(handle)
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["signingCertificate"], "Apple Distribution")
        self.assertEqual(options["provisioningProfiles"]["com.sanylax.continuity.share"], "ContinuityShareCIStore")

    def test_serial_normalization_ignores_colons_and_padding(self):
        self.assertEqual(signing.normalize_serial("00:AB:0C"), "ab0c")

    def test_p12_export_round_trips_the_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "key.pem"
            cert = Path(tmp) / "cert.pem"
            p12 = Path(tmp) / "cert.p12"
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-keyout",
                    str(key),
                    "-out",
                    str(cert),
                    "-days",
                    "1",
                    "-nodes",
                    "-subj",
                    "/CN=Continuity CI Distribution",
                ],
                check=True,
                capture_output=True,
            )
            password = "test-password"
            signing.export_p12(key, cert, p12, password)
            der = signing.p12_certificate_der(p12, password)
            self.assertTrue(der.startswith(b"\x30"))
            self.assertTrue(signing.certificate_serial(der))

    def test_password_is_stable_and_not_the_key_itself(self):
        key = b"not-a-real-p8"
        self.assertEqual(signing.p12_password(key), signing.p12_password(key))
        self.assertNotIn("not-a-real-p8", signing.p12_password(key))


def raw_to_der(raw: bytes) -> bytes:
    def encode(component: bytes) -> bytes:
        component = component.lstrip(b"\x00") or b"\x00"
        if component[0] & 0x80:
            component = b"\x00" + component
        return bytes([0x02, len(component)]) + component

    body = encode(raw[:32]) + encode(raw[32:])
    return bytes([0x30, len(body)]) + body


if __name__ == "__main__":
    unittest.main()
