# Architecture Decision Records

Project: BedrockHarbor  
Status: foundation recorded  
Platform: macOS 14+, Apple Silicon, Swift 6

## ADR-001 — Single repository, single root Swift package

**Decision.** One repo, one `Package.swift`, multiple SPM targets.

**Rationale.** Compile-time dependency boundaries without multi-repo overhead.
Products expose libraries for tests and one executable for the app.

## ADR-002 — Layered targets, composition root in the app

```
BedrockHarbor (executable)
  ├─ HarborFeatures (SwiftUI)
  ├─ HarborApplication (use cases)
  ├─ HarborGooglePlay (store adapter)
  ├─ HarborRuntime (runtime/process)
  ├─ HarborPlatform (storage/net/security/archives)
  └─ HarborCompatibility (pure rules)
         └─ HarborDomain (models + contracts)
```

Application workflows depend on protocols. Concrete adapters are constructed in
the app composition root and injected. No global service locator.

## ADR-003 — Runtime is an external process

mcpelauncher client (when qualified) is launched via Foundation `Process` with a
typed `LaunchPlan`. Swift does not link runtime libraries. Helper executables
are independently written and receive only scoped, session-authenticated IPC.

## ADR-004 — Independent Google Play provider

`HarborGooglePlay` implements authentication, device bootstrap, entitlement,
catalog, and delivery resolution. It does not depend on FinskyKit and does not
copy mcpelauncher-swift. Wire schemas, if used, are individually reviewed
Apache-2.0 materials.

## ADR-005 — Secrets stay in Keychain

`CredentialStore` uses `SecItem`. Tokens never appear in Codable metadata,
environment variables, argv, logs, or diagnostic exports by default. Helpers
request narrow operations; they do not receive bulk token dumps.

## ADR-006 — Pure compatibility engine

`HarborCompatibility` evaluates versioned JSON rules against immutable snapshots.
No network, no filesystem, no scripts in rules. Statuses: `unsupported`,
`unknown`, `partiallyCompatible`, `compatible`. Missing evidence never becomes
a green check.

## ADR-007 — Immutable installations, isolated profile data

Committed game installations are immutable. Profiles own distinct game-data
roots. Deletion of an installation never deletes worlds. Version changes create
verified backups before the first launch on the new build.

## ADR-008 — Feasibility gate before public UI polish

Public MVP claims require a real-machine gate:

`sign-in → ownership → ARM64 package set → approved runtime → launch → local world create/save/reopen`

Failed gate blocks the affected capability; it does not authorize weakened
credential storage or copying upstream implementations.

## ADR-009 — Hardened archives

All game/content extraction goes through one archive service that rejects path
traversal, links (except validated trusted-runtime layouts), bombs, and
collisions, and extracts only into private staging.

## ADR-0010 — Licensing posture

Original code Apache-2.0. Do not distribute GPL runtime binaries with the
launcher MVP; download approved upstream artifacts. Document notices, provenance,
and unofficial status. Separate-process design is an architectural choice, not
an automatic legal exemption.
