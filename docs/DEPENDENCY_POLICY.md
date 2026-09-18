# Dependency Policy

BedrockHarbor is an independent implementation. This document records which
third-party materials are allowed, how they are reviewed, and what is banned.

## Principles

1. Original BedrockHarbor code is Apache-2.0.
2. Do **not** copy, translate, or derive implementation from mcpelauncher-swift,
   FinskyKit, or GPL launcher/runtime source into this application.
3. Runtime binaries are **not** bundled in the launcher distribution. Approved
   artifacts are downloaded from upstream after qualification.
4. Every third-party dependency needs: license file, notice retention, and a
   recorded reason for inclusion.
5. Process boundary between launcher and runtime does **not** automatically
   resolve GPL interaction. Distribution arrangements require legal review
   before public release.

## Allowed dependencies (initial)

| Dependency | Version pin | Target scope | License | Reason |
|---|---|---|---|---|
| ZIPFoundation | 0.9.20 | `HarborPlatform` only (behind `ArchiveService`) | MIT | ZIP read/write without shelling out |
| SwiftProtobuf | 1.38.1 | `HarborGooglePlay` only | Apache-2.0 + Runtime Library Exception | Play wire decoding |
| Sparkle | 2.10.0 | App update adapter only | MIT-style | macOS app updates |

Swift tools: **6.2+** (local toolchain 6.4). Language mode: Swift 6.
Deployment target: macOS 14 on Apple Silicon.

## Reviewed / candidate materials

| Material | Status | Notes |
|---|---|---|
| Google-Play-API (minecraft-linux) | Candidate protocol definitions | Apache-2.0; review file-by-file before use; implement independently |
| mcpelauncher-manifest / macos-builder releases | Runtime catalog inputs | Download artifacts; do not link libraries into Swift |
| mcpelauncher-updates patches | **Blocked** until provenance/storage audit | File-backed credential cache + README source/binary mismatch |
| mcpelauncher-swift | Reference only | No code copy; observe integration requirements only |
| FinskyKit | **Banned** | Product decision: independent provider |

## Ban list

- FinskyKit
- Copied mcpelauncher-swift sources or UI assets
- General-purpose DI frameworks (Swinject, etc.)
- Third-party state-management frameworks (TCA, etc.)
- Arbitrary nightly/unqualified runtime assets in the approval catalog
- Minecraft binaries or Play credentials in the repository or CI

## Approval catalog rules (runtimes & patches)

A runtime or patch enters the supported catalog only with:

- Exact upstream release and asset identity
- Artifact SHA-256
- Architecture and minimum OS
- Executable/resource layout descriptor
- Helper requirements
- Patch provenance and license for every bundled binary
- Qualification evidence (feasibility gate + documented limitations)
- Corresponding-source links when GPL artifacts are involved

## Notice retention

`NOTICE` must list:

- ZIPFoundation copyright and MIT text reference
- SwiftProtobuf copyright
- Sparkle copyright and security documentation link
- Any upstream schema files retained under Apache-2.0 with attribution
- Unofficial-project disclaimer (not affiliated with Mojang, Microsoft, or Google)

## Update policy

- Pin package resolutions in CI.
- Bump a dependency only after license re-check and target-scope check.
- Sparkle updates **BedrockHarbor only**. Runtime updates go through HarborRuntime.
