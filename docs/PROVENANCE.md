# Provenance Ledger

Record every upstream material studied, incorporated, or rejected.

## Studied (research only — no code copied into BedrockHarbor)

| Source | Access | Use |
|---|---|---|
| [mcpelauncher-manifest](https://github.com/minecraft-linux/mcpelauncher-manifest) | Read README/build layout | Confirm runtime/management split |
| [macos-builder workflow](https://github.com/minecraft-linux/macos-builder/blob/main/.github/workflows/main.yml) | Read packaging steps | Architecture must be inspected, not inferred from DMG name |
| [macos-builder v1.8.4-573](https://github.com/minecraft-linux/macos-builder/releases/tag/v1.8.4-573) | Release metadata (2026-09-18 observed) | Qualification candidate only |
| [mcpelauncher-client main.cpp](https://github.com/minecraft-linux/mcpelauncher-client/blob/78904982c13d7bcec7af4b572b18cac83d930d31/src/main.cpp) | CLI argument review | Launch adapter must bind to qualified interface |
| [playdl-signin-ui-qt googleloginwindow.cpp](https://github.com/minecraft-linux/playdl-signin-ui-qt/blob/master/src/googleloginwindow.cpp) | Sign-in approach review | Independent auth design input |
| [mcpelauncher-updates validation.hpp](https://github.com/minecraft-linux/mcpelauncher-updates/blob/main/src/validation.hpp) + README | Credential storage review | **Blocked** pending audit |
| [mcpelauncher-moddb](https://github.com/minecraft-linux/mcpelauncher-moddb) | Trust model review | Maintainer input only, not production trust root |
| [mcpelauncher-swift](https://github.com/hugonote/mcpelauncher-swift) | Integration requirements only | No code copy |
| [mcpelauncher MSA docs](https://minecraft-linux.github.io/source_build/msa.html) | Xbox auth notes | Store account ≠ game identity |
| [upstream FAQ](https://minecraft-linux.github.io/faq/index.html) | Ownership/platform notes | Google Play entitlement required for upstream downloads |
| [Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) | Documented flow | Does **not** prove Play download authorization |
| [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) | Keychain variants | Login keychain for unsandboxed MVP |
| [WKWebsiteDataStore](https://developer.com/documentation/webkit/wkwebsitedatastore) | Browser isolation | Nonpersistent store required |
| [Microsoft Minecraft file extensions](https://learn.microsoft.com/en-us/minecraft/creator/documents/minecraftfileextensions) | Content formats | `.mcpack` / `.mcaddon` / `.mcworld` / `.mctemplate` semantics |
| [GPL FAQ](https://www.gnu.org/licenses/gpl-faq.html.en) / [GPLv3](https://www.gnu.org/licenses/gpl.en.html) | Licensing | Separate process ≠ automatic exemption |
| [Apple distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html) | Signing/notarization | Outside-store requirements |
| [Sparkle security](https://github.com/sparkle-project/sparkle-project.github.io/blob/master/documentation/index.md) | App updates | Ed25519 appcast signatures |
| [Google Play terms](https://play.google.com/about/play-terms/), [Minecraft EULA](https://www.minecraft.net/en-us/eula), [usage guidelines](https://www.minecraft.net/en-us/usage-guidelines) | Product/legal | Unofficial project notice required |

## Incorporated third-party code

| Item | Version | License | Location |
|---|---|---|---|
| (none yet — Package.swift pins added when adapters land) | — | — | — |

## Rejected / blocked

| Item | Reason |
|---|---|
| FinskyKit | Product ban — independent provider |
| mcpelauncher-swift implementation | Independence requirement |
| mcpelauncher-updates release binaries as catalog entries | Credential storage + binary/source mismatch unresolved |
| Bundled full upstream version DB | Licensing not established |
| Arbitrary APK import (MVP) | Needs provenance + APK signature validation |

## Release qualification log

| Date | Host | Runtime candidate | Game build | Gate result | Notes |
|---|---|---|---|---|---|
| — | — | — | — | not run | Feasibility gate pending real account + artifact verification |
