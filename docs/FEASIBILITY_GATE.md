# Feasibility Gate

Public MVP claims require this complete path on a real Apple Silicon Mac:

1. Google Play sign-in (independent adapter, no FinskyKit / no copied Swift launcher code)
2. Ownership / entitlement verification for the signed-in account
3. Obtain a complete **arm64-v8a** Minecraft package set (base + required splits)
4. Install an **approved** upstream runtime (hash + layout + architecture verified)
5. Launch a native ARM64 game process
6. Create, save, exit, and reopen a local world
7. Confirm no credential leakage into files, logs, reports, or helper diagnostics

## Why the gate is mandatory

1. **Google auth is not a standard OAuth checkbox.** Desktop OAuth documentation
   does not establish that resulting tokens authorize consumer Play downloads.
   Auth capability and Play delivery capability must be tested separately.
2. **Some upstream compatibility components conflict with security requirements.**
   Inspected patch code uses a file-backed Play credential cache; its README
   states release binaries may contain more code than published source. Those
   artifacts stay out of the approved catalog until storage behavior and
   provenance are resolved.

## Pass / fail policy

| Outcome | Action |
|---|---|
| Full path passes | Record evidence in `docs/PROVENANCE.md`, enable the qualified combination |
| Partial (e.g. auth works, delivery does not) | Keep capability disabled; publish accurate limitation |
| Credential storage cannot meet policy | Do not enable the integration; do not weaken Keychain policy |
| Runtime layout undocumented | Produce versioned layout descriptor + qualification tests before catalog entry |

Failed checks **block** the affected capability. They do not authorize:

- copying mcpelauncher-swift or FinskyKit
- writing tokens to files/argv/env
- disabling Gatekeeper / TLS validation
- marketing an unverified combination as supported

## Research artifacts required before “live” flags flip

- [ ] Sanitized Play authentication contract + fixtures
- [ ] Entitlement query notes for the test account (no secrets)
- [ ] Delivery resolution notes: split set, expiry, integrity field semantics
- [ ] Runtime asset identity: tag, filename, SHA-256, Mach-O arch, dependent libs
- [ ] Runtime layout descriptor (executable, resources, helper placement)
- [ ] Observed `--data-dir` isolation evidence (worlds, settings, IPC)
- [ ] Patch provenance inventory (hash, license, source, storage behavior)
- [ ] Compatibility matrix row for the qualified build/runtime pair
- [ ] Manual acceptance checklist results on macOS 14 + current macOS

## Local composition switch

`HarborGooglePlay.PlayPolicy.foundation` keeps live network and live auth disabled.
Research builds may use `PlayPolicy.liveResearch` **only** with local, non-committed
credentials and must not publish entitlement/delivery as supported until the gate
row is recorded.

## Candidate runtime (not approved)

| Field | Value |
|---|---|
| Upstream tag | `v1.8.4-573` |
| Project | minecraft-linux/macos-builder |
| Observed | 2026-09-18 |
| Approval | **Not approved** — hash, arch, layout, helpers, patch set unknown |

Replace `RuntimeCandidates.macosBuilderV184_573` placeholders only after download
verification and layout inspection.
