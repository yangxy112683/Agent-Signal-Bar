# GitHub Release Management

This repository uses GitHub Actions for continuous integration and tag-based releases.

## Daily Checks

Every push and pull request to `main` runs:

- shell script syntax checks
- `swift test`
- `./script/verify_local_integrations.sh`

Workflow file:

```text
.github/workflows/ci.yml
```

## Release Flow

Releases are created from Git tags. Use semantic version tags:

```bash
v1.0.0
v1.0.1
v1.1.0
```

To publish a new release:

```bash
git status --short
git pull --ff-only
git tag v1.0.0
git push origin v1.0.0
```

Pushing the tag starts:

```text
.github/workflows/release.yml
```

The release workflow runs tests, packages the app, verifies checksums, and uploads:

- `AgentSignalLight-local.zip`
- `AgentSignalLight-local.dmg`
- `AgentSignalLight-release-manifest.json`
- `AgentSignalLight-SHA256SUMS.txt`

## Version Checklist

Before tagging a new version, confirm:

- `script/package_app.sh` has the intended `CFBundleShortVersionString`.
- `Sources/AgentSignalLight/Services/ReleaseInfo.swift` has the same fallback version.
- `README.md` and `README.zh-CN.md` describe the current behavior.
- `./script/verify_release_all.sh --skip-package` passes if artifacts already exist.
- `./script/verify_release_all.sh` passes for a full local release gate.

## Commit Identity

Use the GitHub noreply identity so commits are attributed to the `guan-ops` account while keeping the real email private:

```bash
git config --global user.name "Hemi Guan"
git config --global user.email "202207961+guan-ops@users.noreply.github.com"
```

## Notes

The generated DMG is a local/self-use build unless Developer ID signing and notarization credentials are configured. See `docs/RELEASE_CHECKLIST.md` for distribution readiness.

