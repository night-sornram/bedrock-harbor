# BedrockHarbor

Independent SwiftUI macOS launcher for Minecraft: Bedrock (Apple Silicon).

BedrockHarbor manages installations, profiles, compatibility, diagnostics, and
user data. It runs the existing mcpelauncher runtime as a **separate process**
and implements Google Play acquisition **independently** — without FinskyKit
and without copying mcpelauncher-swift.

> **Unofficial project.** Not affiliated with Mojang, Microsoft, or Google.

## Status

Foundation build (architecture, domain contracts, compatibility engine,
platform security primitives, native UI shells, feasibility-gate scaffolding).

**Public MVP claims are blocked on the feasibility gate:**

`sign in → verify Google Play ownership → obtain arm64-v8a package set → install approved runtime → launch → create/save/reopen a local world`

Until that path is demonstrated on a real Apple Silicon Mac, store onboarding
and game launch remain disabled rather than weakening credential handling.

See [docs/FEASIBILITY_GATE.md](docs/FEASIBILITY_GATE.md).

## Requirements

- macOS 14+
- Apple Silicon (arm64)
- Swift 6.2+ toolchain (developed against Swift 6.4)

## Package layout

| Target | Role |
|---|---|
| `HarborDomain` | Immutable models + provider contracts |
| `HarborCompatibility` | Pure, versioned rules evaluator |
| `HarborPlatform` | Keychain, redaction, paths, metadata, archive policy |
| `HarborApplication` | Use cases, launch gate, session coordination, Doctor |
| `HarborGooglePlay` | Independent Play adapter (gated live traffic) |
| `HarborRuntime` | Approval catalog, artifact verification, process plan |
| `HarborFeatures` | SwiftUI feature screens |
| `BedrockHarbor` | App entry + composition root |

## Build & test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The complete test suite needs full Xcode for its XCTest targets. Account tests
use isolated temporary stores and do not read or overwrite real user credentials.
See [Google Play session status](docs/GOOGLE_PLAY_SESSION.md) for the authentication
state model and helper protocol.

Run the executable target (SPM host, not a signed `.app` yet):

```bash
swift run BedrockHarbor
```

The UI uses `@Observable` models and explicit `Binding` values. Packaging uses an
optimized Release build and bundles the Google Play helpers. Distribution signing
and notarization require Developer ID credentials.

See `docs/ARCHITECTURE.md` and `docs/DEPENDENCY_POLICY.md`.

## Security posture (foundation)

- Secrets live in the macOS login Keychain via `CredentialStore`.
- Tokens are not written to JSON metadata, argv, env, or logs.
- Diagnostic text is redacted before preview/export.
- Game/content archive entries reject traversal, absolute paths, and symlinks.
- Compatibility never turns missing evidence into a green check.
- Blocked patches stay blocked until provenance and credential storage are audited.

## Licensing

Original BedrockHarbor code: [Apache-2.0](LICENSE).

Runtime binaries are **not** bundled. Approved artifacts are downloaded from
upstream after qualification. GPL interaction and corresponding-source duties
require review before redistribution — a separate process is not an automatic
legal exemption. Dependency and provenance notes:

- [docs/DEPENDENCY_POLICY.md](docs/DEPENDENCY_POLICY.md)
- [docs/PROVENANCE.md](docs/PROVENANCE.md)

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — ADRs
- [docs/FEASIBILITY_GATE.md](docs/FEASIBILITY_GATE.md) — release gate checklist
- Implementation plan retained in project history / planning notes
