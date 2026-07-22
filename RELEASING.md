# Releasing Bridgeport

Bridgeport uses two separate automation paths:

- **CI** runs on `main`, pull requests, manual dispatch, and as a reusable release gate. It builds and tests on the GitHub-hosted `macos-26` image, assembles a fresh app bundle, performs an isolated clean-install probe, and scans full Git history with Gitleaks.
- **Release** runs for `v*` tags or manual dispatch. It calls the CI workflow first, then creates the GitHub release. Signing and notarization remain local because their credentials are held in 1Password and the local Developer ID keychain.

## Public-Release Gate

This gate was completed on 2026-07-20: the repository is public under GPL-3.0 (`LICENSE`), the tree was confirmed free of private deployment values (the only `amesvt.com` match in code is the clean-install probe that scans for leaks), and full-history Gitleaks passed, so no history rewrite was needed. Re-run this review before any future visibility change in the other direction or if deployment-specific values ever land in the tree.

## Local Preflight

From a clean worktree on a supported Mac:

```bash
swift test
python3 test_client.py
swift build -c release
gitleaks git . --redact
script/build_and_run.sh --build-only
script/verify_clean_install.sh dist/Bridgeport.app
```

The clean-install probe copies the app into a temporary Applications directory, starts its bundled executable with an isolated `BRIDGEPORT_CONFIG_HOME`, checks the authenticated status endpoint, verifies generated-file permissions, and removes the temporary installation.

## Sign, Notarize, and Verify

Choose the next version, then run:

```bash
script/package_release.sh 1.0.6
script/notarize_release.sh dist/release/Bridgeport-1.0.6.dmg
script/verify_clean_install.sh dist/release/Bridgeport-1.0.6.dmg --require-notarized
```

`package_release.sh` requires a Developer ID Application identity. `notarize_release.sh` resolves App Store Connect credentials through the canonical 1Password-backed environment and never writes them to the repository.

## Sparkle Appcast

Every release must also be signed for Sparkle and appended to `appcast.xml` on `main`, which installed apps poll via the raw GitHub URL declared in `SUFeedURL`.

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update \
  dist/release/Bridgeport-1.0.6.dmg --account bridgeport
```

The EdDSA private key lives in the login Keychain under the `bridgeport` account (created with `generate_keys --account bridgeport`; the matching `SUPublicEDKey` is embedded in both Info.plist heredocs). Add an `<item>` to `appcast.xml` with the new version, the GitHub release download URL as the enclosure, and the `sparkle:edSignature` and `length` values printed by `sign_update`. Then sign and verify the complete feed before committing it:

```bash
script/sign_appcast.sh
```

`SURequireSignedFeed` makes this second signature mandatory. The enclosure signature protects the downloaded update archive; it does not sign the appcast XML. Commit the signed appcast with the release-notes commit so the feed and the tag land together.

## Publish

Add `docs/release-notes/v1.0.6.md`, commit and push the release changes, then create and push an annotated tag:

```bash
git tag -a v1.0.6 -m "Bridgeport 1.0.6"
git push origin v1.0.6
```

After the Release workflow creates the GitHub release, attach the verified DMG and checksum:

```bash
shasum -a 256 dist/release/Bridgeport-1.0.6.dmg \
  > dist/release/Bridgeport-1.0.6.dmg.sha256
gh release upload v1.0.6 \
  dist/release/Bridgeport-1.0.6.dmg \
  dist/release/Bridgeport-1.0.6.dmg.sha256 \
  --clobber
```

Confirm the release page contains the intended notes and artifact, download the DMG on another supported Mac when practical, and rerun `script/verify_clean_install.sh` against that downloaded artifact.
