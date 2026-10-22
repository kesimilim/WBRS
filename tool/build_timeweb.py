#!/usr/bin/env python3
"""Build the native Timeweb client; keep QA APKs distinct from store candidates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'config/timeweb.production.json'


def build_command(mode, number, version, environ, target_platform=None):
    if target_platform is not None and (mode != "qa" or target_platform != "android-arm64"):
        raise ValueError("A restricted architecture is supported only for the ARM64 QA build.")
    if not re.fullmatch(r'[1-9][0-9]*', number) or int(number) > 2100000000:
        raise ValueError('Use a positive Android build number, at most 2100000000.')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Use a version such as 1.0.25.')
    config = json.loads(CONFIG.read_text())
    if (config.get('CLRS_APP_BACKEND') != 'timeweb'
            or config.get('CLRS_AUTH_LIFECYCLE_BACKEND') != 'timeweb'
            or config.get('CLRS_USE_EMULATORS') is not False
            or not config.get('CLRS_TIMEWEB_API_ORIGIN', '').startswith('https://')
            or not re.fullmatch(r'[a-f0-9]{64}', config.get('CLRS_TIMEWEB_SOURCE_SNAPSHOT', ''))):
        raise ValueError('Invalid production Timeweb configuration.')
    enabled = ('AUTH', 'PROFILE_EDITOR', 'TEMPERAMENT', 'OWN_PROFILE',
               'CHATS', 'AUTH_LIFECYCLE', 'REGISTRATION')
    if any(config.get('CLRS_TIMEWEB_' + name + '_ENABLED') is not True for name in enabled):
        raise ValueError('A required Timeweb feature is disabled.')
    env = dict(environ, CI='true', FLUTTER_SUPPRESS_ANALYTICS='true',
               CLRS_ANDROID_SIGNING_MODE=mode)
    if mode == 'store':
        settings = env.get('CLRS_ANDROID_SIGNING_PROPERTIES', '')
        if not settings or not Path(settings).is_file():
            raise ValueError('Original signing properties are required; no debug-key fallback.')
        certificate = env.get('CLRS_STORE_CERT_SHA256', '').lower().replace(':', '')
        if not re.fullmatch(r'[a-f0-9]{64}', certificate):
            raise ValueError('CLRS_STORE_CERT_SHA256 must identify the existing store APK certificate.')
    flutter = env.get('FLUTTER_BIN', 'flutter')
    command = [flutter, 'build', 'apk', '--release', '--flavor', 'production',
               '--build-name=' + version, '--build-number=' + number,
               '--dart-define-from-file=' + str(CONFIG)]
    if target_platform:
        command.append("--target-platform=" + target_platform)
    return command, env


def verify_signature(output, expected=None):
    certificates = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})$',
                              output, flags=re.MULTILINE)
    if len(certificates) != 1:
        raise ValueError('Expected one verified APK signing certificate.')
    certificate = certificates[0].lower()
    if expected:
        if 'CN=Android Debug' in output or certificate != expected.lower().replace(':', ''):
            raise ValueError('APK certificate differs from the original store certificate or is a debug key.')
    return certificate


def verify_package(output, number, version):
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
                        output, flags=re.MULTILINE)
    if not package or package.groups() != ('com.lrs', number, version):
        raise ValueError('APK package or version differs from the requested CLRS build.')


def verify_native_libraries(apk):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
    abis = sorted({name.split('/')[1] for name in names
                   if name.startswith('lib/') and name.endswith('.so') and len(name.split('/')) == 3})
    if not abis or any('lib/' + abi + '/' + library not in names
                       for abi in abis for library in ('libapp.so', 'libflutter.so')):
        raise ValueError('APK advertises a native architecture without the Flutter runtime.')
    return abis


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('qa', 'store'), default='qa')
    parser.add_argument('--build-number', default=os.environ.get('CLRS_BUILD_NUMBER'))
    parser.add_argument('--version', default='1.0.25')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--target-platform', choices=('android-arm64',), help='Optional ARM64-only QA build.')
    args = parser.parse_args(argv)
    if not args.build_number:
        parser.error('Set --build-number (greater than the previous release) or CLRS_BUILD_NUMBER.')
    command, env = build_command(args.mode, args.build_number, args.version, os.environ, args.target_platform)
    if args.dry_run:
        print(json.dumps({'command': command, 'signingMode': args.mode}, indent=2))
        return
    sdk = env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME')
    if not sdk:
        raise ValueError('Set ANDROID_SDK_ROOT or ANDROID_HOME.')
    apksigner = Path(sdk) / 'build-tools/35.0.0/apksigner'
    aapt = apksigner.with_name('aapt')
    if not apksigner.is_file() or not aapt.is_file():
        raise ValueError('Android SDK build-tools 35.0.0 are required to verify the APK.')
    tracked_changes = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
    if args.mode == 'store' and tracked_changes:
        raise ValueError('Commit reviewed source changes before creating a store candidate.')
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    source = ROOT / 'build/app/outputs/flutter-apk/app-production-release.apk'
    signature = subprocess.check_output([str(apksigner), 'verify', '--print-certs', str(source)],
                                        cwd=ROOT, env=env, text=True)
    expected = env.get('CLRS_STORE_CERT_SHA256') if args.mode == 'store' else None
    certificate = verify_signature(signature, expected)
    package = subprocess.check_output([str(aapt), 'dump', 'badging', str(source)],
                                      cwd=ROOT, env=env, text=True)
    verify_package(package, args.build_number, args.version)
    abis = verify_native_libraries(source)
    if args.target_platform and abis != ["arm64-v8a"]:
        raise ValueError("ARM64 QA build contains unexpected native architectures.")
    destination = ROOT / 'build/delivery' / args.mode
    destination.mkdir(parents=True, exist_ok=True)
    name = 'CLRS-{}-{}-Timeweb-{}.apk'.format(args.version, args.build_number, args.mode.upper())
    if args.target_platform:
        name = name.replace('.apk', '-ARM64.apk')
    apk = destination / name
    shutil.copy2(source, apk)
    manifest = {
        'file': name, 'versionName': args.version, 'versionCode': int(args.build_number),
        'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'sourceDirty': bool(tracked_changes), 'backend': 'timeweb', 'signingMode': args.mode,
        'certificateSha256': certificate, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'configurationSha256': hashlib.sha256(CONFIG.read_bytes()).hexdigest(),
        'nativeAbis': abis,
        'storePublished': False, 'releaseAcceptanceComplete': False,
    }
    apk.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('APK: ' + str(apk))
    print('QA only; not for publication.' if args.mode == 'qa'
          else 'Certificate verified. Store acceptance and publication are separate steps.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('Timeweb build stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
