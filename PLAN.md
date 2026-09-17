# JustArc — macOS archiver (BetterZip-style) — Implementation Plan

Date: 2026-09-17

## 1. Product behaviour (what we are building)

Two modes, chosen at launch:

**A. Quick Extract (launched by double-clicking an archive)**
- No main window. One small progress panel per archive (name, %, cancel).
- Extract next to the archive (default) or to a configured folder (Downloads / Ask each time).
- "Smart folder": if the archive has more than one top-level item, create `<archive name>/`; otherwise extract the single item directly.
- Encrypted archive → password sheet (show/hide, "remember in Keychain for this archive").
- After extraction: optional Reveal in Finder, optional Move archive to Trash.
- When the last extraction finishes and no browser windows are open → `NSApp.terminate`.
- Override: hold ⌥ while opening (or Preferences per format) → open in browser instead of extracting.

**B. Browser (launched from Dock/Spotlight, or Open… / ⌥-open)**
- Launch with no files → empty untitled archive window (WinRAR/BetterZip style). Drag files in, Save As → pick format.
- Open archive → folder tree + file list (name, size, packed, modified, CRC, attrs, encrypted flag), path bar, filter field.
- Double-click a file → extract to temp, open with default app. Space → Quick Look (QLPreviewPanel).
- Extract Selected / Extract All, Add files/folders (drag-in, toolbar, ⌘O), Delete, Rename, New Folder, Test archive, Set/Change password.
- Drag entries out to Finder (NSFilePromiseProvider → extracted on drop).
- Save (in place, when format supports it) / Save As (rebuild in any writable format).

## 2. Format matrix

| Format | Read | Write | Password read | Password write | Engine |
|---|---|---|---|---|---|
| zip (zip64, jar/ipa/apk/epub) | ✓ | ✓ (Deflate/Store, levels) | ZipCrypto + AES | ZipCrypto + AES-256 | 7zz |
| 7z | ✓ | ✓ (LZMA2, solid, levels) | AES-256 (+ encrypted headers) | AES-256 (+ encrypted headers) | 7zz |
| rar / rar5 (incl. multi-volume) | ✓ | only if user-installed `rar` binary present | ✓ | ✓ via `rar` | 7zz (read), rar CLI (write) |
| tar, tar.gz/tgz, tar.bz2, tar.xz, tar.zst, tar.lz4 | ✓ | ✓ | n/a | n/a | 7zz (bsdtar fallback for xattrs) |
| gz, bz2, xz, zst, lz4 (single file) | ✓ | ✓ | n/a | n/a | 7zz |
| dmg (UDIF: UDZO/ULFO/UDBZ/UDRW, HFS+/APFS) | ✓ | ✓ | AES-128/256 | AES-128/256 | hdiutil (mount-based) |
| iso, cab, xar/pkg, cpio, ar/deb, rpm, wim, lzh, arj, z | ✓ | iso/xar/cpio via 7zz | – | – | 7zz |
| sit/sitx, legacy Mac formats | phase 4 | – | – | – | XADMaster (The Unarchiver's framework) |

RAR write cannot be bundled (RARLAB licence). Detect `rar` at `/usr/local/bin`, `/opt/homebrew/bin`, or a user-chosen path; show "Install RAR…" link otherwise. Same policy BetterZip uses.

## 3. Architecture

Language: Swift 6, AppKit (NSDocument-based). SwiftUI only for Preferences and the Save-panel accessory. Deployment target macOS 14. Universal binary. Direct distribution (Developer ID + notarization + Sparkle); not sandboxed in v1 (hdiutil mounting and arbitrary-path extraction are painful in the sandbox — revisit for App Store later).

```
JustArc.xcodeproj
├─ JustArcCore/            Swift package, no AppKit — fully unit-testable
│  ├─ ArchiveEngine.swift  protocol: probe, list, extract(entries,to,password), create, add, delete, rename, test
│  ├─ Engines/
│  │   ├─ SevenZipEngine   wraps bundled `7zz` (Process + pipes, parses `l -slt`, progress from `-bsp1`)
│  │   ├─ DMGEngine        hdiutil attach/detach/create; entries = mounted filesystem
│  │   ├─ RarWriterEngine  external `rar` CLI if present
│  │   └─ TarEngine        bsdtar for tar.* when xattr/resource-fork fidelity matters
│  ├─ Model/               ArchiveEntry (path, size, packed, mtime, crc, isDir, isEncrypted, attrs), EntryTree
│  ├─ Session/             ArchiveSession = open archive + pending edits (adds/deletes/renames) + password
│  ├─ Format/              FormatRegistry (UTI ↔ engine ↔ capabilities ↔ write options)
│  ├─ Security/            path-traversal sanitiser, symlink escape check, size/entry-count limits (zip bombs)
│  └─ Temp/                per-session temp dir under ~/Library/Caches/JustArc, cleaned on close/launch
├─ JustArc/                app target
│  ├─ App/                 AppDelegate (launch-mode decision), Preferences, Keychain
│  ├─ QuickExtract/        QuickExtractController + progress panel
│  ├─ Browser/             ArchiveDocument (NSDocument), window controller, outline/table views, path bar,
│  │                       Quick Look, drag & drop (in/out), toolbar
│  ├─ Save/                SaveAs accessory (format, level, password, encrypt names, split volumes, exclude .DS_Store/._*)
│  └─ Services/            Finder Services & Quick Actions: "Compress", "Extract Here", "Extract To…"
├─ Helpers/                7zz (universal, LGPL), signed with app's team ID → Contents/Helpers
└─ JustArcTests/           fixture archives generated at test time (7zz, zip, hdiutil)
```

Key mechanics
- **Launch-mode decision**: `applicationWillFinishLaunching` sets a flag; if `application(_:open:)` arrives before any window is shown and ⌥ is not held and the format is in the "extract on open" set → Quick Extract; else open documents. `applicationShouldOpenUntitledFile` → true only when launched with no files.
- **Editing model**: the browser never edits the archive live. It records pending ops on `ArchiveSession`. Save applies them: in place via `7zz a/d/rn` for zip/7z/tar when the format is unchanged, otherwise rebuild (extract to temp → apply ops → create new archive → atomic replace). Read-only formats (rar w/o `rar`, dmg, iso, cab) force Save As.
- **Single-file open / Quick Look**: extract only the requested entry (`7zz e -i!path`) into the session temp dir; Quick Look points at that file. Track opened files with a dispatch source; if modified, offer "Update archive with edited file" (BetterZip parity, phase 3).
- **Passwords**: 7zz reports `Encrypted = +` per entry; header-encrypted 7z/rar fail listing → prompt and retry. Password held in memory for the session; optional Keychain item keyed by archive path hash. Known limitation: 7zz and rar take `-p` on the command line (visible to same-user `ps` briefly); hdiutil uses `-stdinpass`. Mitigation later: in-process 7-Zip (`7z.so`-style dylib) behind the same `ArchiveEngine` protocol.
- **DMG**: `hdiutil attach -nobrowse -readonly -noverify -noautoopen -mountpoint <tmp>` (pipe `Y` for SLA images, `-stdinpass` for encrypted). Browse = enumerate the mount; extract = copy; detach on close. Create: `hdiutil create -srcfolder -format UDZO|ULFO -encryption AES-256 -stdinpass`.
- **macOS hygiene**: never add `.DS_Store`, `._*`, `__MACOSX` unless the user opts in; preserve executable bits and symlinks; filename encoding override (`-mcp=` for CP866/Shift-JIS zips).
- **Safety**: reject entries resolving outside the destination, cap total expanded size / entry count with a warning, never follow symlinks out of the destination.

## 4. Info.plist / Launch Services

Declare `CFBundleDocumentTypes` (Viewer for read-only, Editor for writable) for: public.zip-archive, org.7-zip.7-zip-archive, com.rarlab.rar-archive, public.tar-archive, org.gnu.gnu-zip-archive, org.gnu.gnu-zip-tar-archive, public.bzip2-archive, org.tukaani.xz-archive, org.tukaani.tar-xz-archive, com.apple.disk-image-udif, public.iso-image, com.microsoft.cab, public.cpio-archive, com.apple.xar-archive. Export UTIs for zst, tar.zst, lz4, lzh, arj. Preferences → "Set as default for…" with per-format checkboxes (uses `NSWorkspace.setDefaultApplication(at:toOpen:)`).

## 5. Milestones

| # | Milestone | Status | Deliverable |
|---|---|---|---|
| M0 | Skeleton | **done** | SwiftPM package, JustArcCore, bundled 7zz 25.01 universal, list/extract/test/create/add/delete/rename, 42 tests |
| M1 | Quick Extract MVP | **done** | Double-click → extract → quit; password sheet with keychain option; progress/cancel; prefs pane; smart wrapper folders |
| M2 | Browser read-only | **done, except dmg** | Window, folder tree, sortable list, path bar, filter, Quick Look, open single file, extract selected/all, drag-out |
| M3 | Create & edit | **partly done** | Empty archive window, drag-in/add/delete/rename, Save and Save As with format/level/password/encrypt-names all work. Still missing: split volumes in the Save panel, external rar writing, "update edited file" |
| M4 | Polish & ship | not started | Finder Services/Quick Actions, encoding override UI, Sparkle, Developer ID signing, notarized DMG, localisation |
| M5 | Later | not started | hdiutil engine for dmg, XADMaster for sit/legacy, in-process 7z engine (no CLI passwords), App Store variant, Shortcuts actions |

**Note on the dmg engine.** The format registry lists dmg and the Save panel filters
it out, but `DMGEngine` is not written yet, so opening a .dmg falls through to 7zz
and shows the raw UDIF layout rather than the mounted filesystem. This is the next
piece of work.

## 6. Open decisions (defaults chosen, change if you disagree)

- Default handler for `.dmg`: **off** by default (Finder's DiskImageMounter stays); user opts in.
- Sandbox/App Store: **no** for v1.
- Minimum macOS: **14 Sonoma**.
- Extract destination default: **same folder as archive**, smart folder **on**, move-to-trash **off**.
