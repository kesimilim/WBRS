import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import build_timeweb as build


class TimewebReleaseTests(unittest.TestCase):
    def test_qa_command_selects_native_backend_without_emulators(self):
        command, env = build.build_command('qa', '69', '1.0.25', {
            'CLRS_ANDROID_SIGNING_MODE': 'store', 'FLUTTER_BIN': '/opt/flutter/bin/flutter'})
        self.assertEqual(command[0], '/opt/flutter/bin/flutter')
        self.assertEqual(env['CLRS_ANDROID_SIGNING_MODE'], 'qa')
        self.assertIn('--dart-define-from-file=' + str(build.CONFIG), command)
        self.assertIn('--build-number=69', command)
        self.assertEqual(json.loads(build.CONFIG.read_text())['CLRS_APP_BACKEND'], 'timeweb')

    def test_misconfigured_backend_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            config = json.loads(build.CONFIG.read_text())
            config['CLRS_APP_BACKEND'] = 'firebase'
            path.write_text(json.dumps(config))
            with patch.object(build, 'CONFIG', path), self.assertRaises(ValueError):
                build.build_command('qa', '69', '1.0.25', {})

    def test_store_cannot_fall_back_when_key_is_missing(self):
        with patch.dict(build.os.environ, {}, clear=True), patch.object(build.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'no debug-key fallback'):
                build.main(['--mode', 'store', '--build-number', '69'])
            run.assert_not_called()

    def test_store_requires_original_certificate_even_with_properties(self):
        with tempfile.NamedTemporaryFile() as settings:
            with self.assertRaisesRegex(ValueError, 'existing store APK'):
                build.build_command('store', '69', '1.0.25', {
                    'CLRS_ANDROID_SIGNING_PROPERTIES': settings.name})

    def test_debug_certificate_cannot_be_a_store_candidate(self):
        certificate = 'a' * 64
        signature = ('Signer #1 certificate DN: CN=Android Debug, O=Android, C=US\n'
                     'Signer #1 certificate SHA-256 digest: ' + certificate)
        with self.assertRaisesRegex(ValueError, 'debug key'):
            build.verify_signature(signature, certificate)

    def test_signature_mismatch_and_multiple_signers_are_rejected(self):
        signature = 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64
        with self.assertRaises(ValueError):
            build.verify_signature(signature, 'b' * 64)
        with self.assertRaises(ValueError):
            build.verify_signature(signature + '\nSigner #2 certificate SHA-256 digest: ' + 'b' * 64)

    def test_matching_store_certificate_is_accepted(self):
        certificate = 'a' * 64
        self.assertEqual(build.verify_signature(
            'Signer #1 certificate SHA-256 digest: ' + certificate, ':'.join(['AA'] * 32)), certificate)

    def test_invalid_versions_stop_before_build(self):
        for number in ('0', '-1', '2100000001', '69 --dart-define=CLRS_APP_BACKEND=firebase'):
            with self.subTest(number=number), self.assertRaises(ValueError):
                build.build_command('qa', number, '1.0.25', {})

    def test_old_or_sandbox_apk_is_not_delivered_as_requested_release(self):
        for package, number in [('com.lrs.sandbox', '69'), ('com.lrs', '68')]:
            with self.subTest(package=package, number=number), self.assertRaises(ValueError):
                build.verify_package(
                    "package: name='{}' versionCode='{}' versionName='1.0.25'".format(package, number),
                    '69', '1.0.25')

    def test_matching_apk_package_and_version_are_accepted(self):
        build.verify_package("package: name='com.lrs' versionCode='69' versionName='1.0.25'", '69', '1.0.25')

    def test_arm64_is_explicitly_qa_only(self):
        command, _ = build.build_command('qa', '70', '1.0.25', {}, 'android-arm64')
        self.assertIn('--target-platform=android-arm64', command)
        with self.assertRaises(ValueError):
            build.build_command('store', '70', '1.0.25', {}, 'android-arm64')

    def test_plugin_only_abi_cannot_be_delivered(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / 'synthetic.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', b'fixture')
                archive.writestr('lib/arm64-v8a/libflutter.so', b'fixture')
            self.assertEqual(build.verify_native_libraries(apk), ['arm64-v8a'])
            with zipfile.ZipFile(apk, 'a') as archive:
                archive.writestr('lib/x86/libplugin.so', b'fixture')
            with self.assertRaisesRegex(ValueError, 'without the Flutter runtime'):
                build.verify_native_libraries(apk)


if __name__ == '__main__':
    unittest.main()
