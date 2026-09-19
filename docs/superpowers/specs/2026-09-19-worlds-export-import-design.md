# Worlds export/import — design

Date: 2026-09-19

## Goal

Let the user move Minecraft worlds ("maps") in and out of Harbor: export any
world from the active profile as a standard `.mcworld` file (opens on Windows,
Android, iOS, and other launchers), and import a `.mcworld` / `.zip` file (or an
already-extracted world folder) into the active profile.

## Where worlds live

The launcher runtime starts with `-dd <dataDirectory>` where
`dataDirectory = HarborPaths.gameDataDirectory/<profile.dataRootID>` and the
game creates its content under `games/com.mojang`. Worlds therefore live at:

```
~/Library/Application Support/BedrockHarbor/GameData/<dataRootID>/games/com.mojang/minecraftWorlds/<world>/
```

`HarborPaths.profileDataURL(dataRootID:)` already resolves the
`games/com.mojang` part. The new service only adds `minecraftWorlds`.

## Approach chosen (and alternatives)

**Chosen: system tools via `HarborSubprocess`, no new dependencies.**

- Export: `/usr/bin/ditto -c -k --norsrc --noextattr <worldDir> <dest>.mcworld`
  — verified empirically: archives the folder *contents* at the zip root (the
  `.mcworld` convention) with no AppleDouble `._*` junk.
- Import: `/usr/bin/unzip -Z1 <archive>` lists entries → every entry is
  validated with the existing hardened `ArchivePathPolicy.evaluateEntryPath`
  (rejects absolute paths, `..` traversal, symlinks, non-canonical Unicode)
  → `/usr/bin/ditto -x -k <archive> <staging>` extracts.
- This matches the established codebase pattern (CompatibilityPatches already
  extracts with `ditto -x -k` through `HarborSubprocess`).

Alternatives rejected:
- *ZIPFoundation dependency* — allowed by docs/DEPENDENCY_POLICY.md but the
  package currently ships zero dependencies; system tools keep it that way.
- *Pure-Swift zip* — disproportionate for a convenience feature.

## Components

### `HarborApplication/WorldArchiveService.swift` (new, no AppKit)

- `struct MinecraftWorld`: `id` (folder name), `name` (`levelname.txt`),
  `directoryURL`, `modifiedAt`, `byteSize`.
- `listWorlds(profileDataURL:)` — enumerates `minecraftWorlds`, decodes
  `levelname.txt` (UTF-16LE BOM **or** UTF-8 — Bedrock writes both depending
  on version), sums folder sizes.
- `exportWorld(_:to:)` — ditto create; writes to a temp file first, then moves
  to the destination so a cancelled save never leaves a half-written archive.
- `importWorld(from:profileDataURL:)` — staged under
  `stagingCache/world-import-<uuid>/`; for archives validates entries, extracts,
  then **descends a single wrapping folder** (some tools wrap the world in
  `MyName/`); validates the result looks like a world (`levelname.txt`,
  `level.dat`, `db/`, `world_db/`, or `world_*_packs/`); moves it to
  `minecraftWorlds/<fresh-UUID>/` (never overwrites an existing world);
  cleans staging. Returns the imported `MinecraftWorld`.
- Import validation failures throw the existing `HarborError.archiveRejected`.

### `HarborFeatures/WorldsView.swift` (new section)

New sidebar item **Worlds** (SF Symbol `map`), second position after Play.
Lists each world (name, folder id, last modified, size) with **Export** and
**Reveal in Finder** per row, an **Import world…** button, the shared
`OperationPhaseView` bound to a new `worldsOperations` tracker, and an empty
state pointing at creating a world in-game first.

### `AppState` (HarborUI.swift)

- `worlds: [MinecraftWorld]`, `worldsOperations`, `loadWorlds()`
  (resolves the selected profile's `profileDataURL`; no profile → empty list).
- `exportWorld(_:)` — `NSSavePanel` pre-filled with `<Name>.mcworld`; refuses
  while the game is running (LevelDB files are locked mid-session).
- `importWorldFromPanel()` — `NSOpenPanel` accepting `.mcworld`/`.zip` files
  or a world folder; same running-game guard; refreshes the list on success.

## Error handling

- Game running → immediate failure message, no partial work.
- Bad archive (traversal, not a world, corrupt) → `archiveRejected` with a
  plain-language reason; nothing is left in `minecraftWorlds`.
- Export to an existing file: NSSavePanel asks; overwrite replaces the file
  atomically after the temp archive is fully written.

## Testing

`Tests/HarborApplicationTests/WorldArchiveServiceTests.swift`:

1. listing reads UTF-16LE and UTF-8 names + sizes;
2. export produces a zip whose entries are world contents at root, no `._*`;
3. export → import round-trip preserves name and file tree;
4. wrapped single-root-folder archives are descended;
5. hand-crafted malicious zip with `../evil` entry is rejected before any
   extraction (zip bytes built in-test, no dependencies);
6. non-world folders/archives are rejected.

UI wiring follows the untested thin-action precedent (`importAPK`).
