# Releasing Bridgeport

Bridgeport uses two separate automation paths:

- **CI** runs on `main`, pull requests, manual dispatch, and as a reusable release gate. It builds and tests on the GitHub-hosted `macos-26` image, assembles a fresh app bundle, performs an isolated clean-install probe, and scans full Git history with Gitleaks.
- **Release** runs for `v*` tags or manual dispatch. It calls the CI workflow first, then creates the GitHub release. Signing and notarization remain local because their credentials are held in 1Password and the local Developer ID keychain.

## Public-Release Gate

Before changing repository visibility, select and add the intended source license. The current repository is copyright Oliver Ames with no grant of reuse, and that legal choice cannot be inferred from the code. Also confirm the current tree contains no private deployment values and decide whether old documentation examples in Git history require a history rewrite or a fresh public repository.

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
