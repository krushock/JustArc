# JustArc — macOS archiver (BetterZip-style) — Implementation Plan

Date: 2026-09-17

> **Design change, 2026-09-18.** The browser was first built to look like WinRAR,
> which is what the original brief asked for. It is now built from stock AppKit
> instead: `NSToolbar` with grouped items, a sidebar split item, the window subtitle
> for the location, a search toolbar item for the filter. On macOS 26 and later the
> system renders those with Liquid Glass and the scroll edge effect without the app
> drawing any of it. The descriptions of a WinRAR-style command strip and address row
> below are kept for the record but no longer describe the app.
>
> The first attempt at this still looked old, and the reason was not the code: SwiftPM
> stamped the executable with the deployment target (14.0) as its SDK version, and
> macOS picks the design from that stamp. The build now records the real SDK.

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
| zip (zip64, jar/ipa/apk/epub) | ✓ | ✓ (Deflate/Store, levels) | ZipCrypto + AES | ZipCrypto + AES-256 | 7z.so |
| 7z | ✓ | ✓ (LZMA2, solid, levels) | AES-256 (+ encrypted headers) | AES-256 (+ encrypted headers) | 7z.so |
| rar / rar5 (incl. multi-volume) | ✓ | only if user-installed `rar` binary present | ✓ | ✓ via `rar` | 7z.so (read), rar CLI (write) |
| tar, tar.gz/tgz, tar.bz2, tar.xz, tar.zst | ✓ | ✓ (not zst) | n/a | n/a | 7z.so |
| gz, bz2, xz, zst, Z (single file) | ✓ | ✓ (gz, bz2, xz) | n/a | n/a | 7z.so |
| dmg (UDIF: UDZO/ULFO/UDBZ/UDRW, HFS+/APFS) | ✓ | ✓ | AES-128/256 | AES-128/256 | hdiutil (mount-based) |
| iso, cab, xar/pkg, cpio, ar/deb, rpm, wim, lzh, arj, z | ✓ | – | – | – | 7z.so |
| sit/sitx, legacy Mac formats | phase 4 | – | – | – | XADMaster (The Unarchiver's framework) |

RAR write cannot be bundled (RARLAB licence). Detect `rar` at `/usr/local/bin`, `/opt/homebrew/bin`, or a user-chosen path; show "Install RAR…" link otherwise. Same policy BetterZip uses.

## 3. Architecture

Language: Swift 6, AppKit (NSDocument-based). SwiftUI only for Preferences and the Save-panel accessory. Deployment target macOS 14. Universal binary. Direct distribution (Developer ID + notarization + Sparkle); not sandboxed in v1 (hdiutil mounting and arbitrary-path extraction are painful in the sandbox — revisit for App Store later).

```
JustArc.xcodeproj
├─ JustArcCore/            Swift package, no AppKit — fully unit-testable
│  ├─ ArchiveEngine.swift  protocol: probe, list, extract(entries,to,password), create, add, delete, rename, test
│  ├─ Engines/
│  │   ├─ SevenZipEngine   7-Zip's format library in process, through the SevenZipBridge C API
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
├─ Frameworks/             7z.so (universal, LGPL, built from vendored source), signed with the app
└─ JustArcTests/           fixture archives generated at test time (7zz, zip, hdiutil)
```

Key mechanics
- **Launch-mode decision**: `applicationWillFinishLaunching` sets a flag; if `application(_:open:)` arrives before any window is shown and ⌥ is not held and the format is in the "extract on open" set → Quick Extract; else open documents. `applicationShouldOpenUntitledFile` → true only when launched with no files.
- **Editing model**: the browser never edits the archive live. It records pending ops on `ArchiveSession`. Save applies them: in place for zip/7z/tar (and tar.gz/bz2/xz, by rewriting the tar and recompressing it) when the format is unchanged, otherwise rebuild (extract to temp → apply ops → create new archive → atomic replace). Read-only formats (rar w/o `rar`, dmg, iso, cab) force Save As.
- **Single-file open / Quick Look**: extract only the requested entry into the session temp dir; Quick Look points at that file. Track opened files with a dispatch source; if modified, offer "Update archive with edited file" (BetterZip parity, phase 3).
- **Passwords**: 7-Zip reports encryption per entry; header-encrypted 7z/rar fail listing → prompt and retry. Password held in memory for the session; optional Keychain item keyed by archive path hash. 7-Zip runs in process, so passwords stay in memory and are wiped when an archive closes; hdiutil uses `-stdinpass`. Only RARLAB's `rar` still takes `-p` on its command line, when writing RAR.
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
| M2 | Browser read-only | **done** | Window, folder tree, sortable list, path bar, filter, Quick Look, open single file, extract selected/all, drag-out, dmg via hdiutil |
| M3 | Create & edit | **done** | Empty archive window, drag-in/add/delete/rename, Save and Save As with format, level, password, encrypted names and split volumes. RAR writing through RARLAB's tool, downloadable from Settings. Edited files are offered back to the archive |
| M4 | Polish & ship | **done, except notarization** | Four Finder Services, filename encoding menu, Sparkle wired and embedded, hardened-runtime signing, installer disk image, English and Russian |
| M5 | In-process 7-Zip | **done** | 7-Zip 25.01 built from source as `7z.so`, loaded through a C bridge: no subprocess, no passwords in argv, split volumes read back, zip encryption method selectable in the engine |
| M6 | Fit into the Finder | **done** | Settings ▸ File Types with a default app per kind of archive; extract, open or ask on double-click; Dock drop and Services always open a window; drops accepted anywhere in the window; folders drag out; `__MACOSX` hidden; app-level drag-and-drop tests |
| M7 | Review and hardening | **done** | Three independent reviews (bridge, engines, app) and the fixes they led to: atomic file replacement on extraction, hostile-archive defences, RAR argument handling, split saves, one operation at a time per window, passwords asked for when needed and remembered only once proven, quit and close that ask before losing work |
| M8 | Quick Look | **done** | Two sandboxed extensions inside the app: Space on an archive in the Finder lists its contents, and its thumbnail shows what is inside. Built and signed by the same script as the app, with no Xcode project |
| M9 | Later | not started | XADMaster for sit/legacy, App Store variant, Shortcuts actions |

**What is not verified.** Notarization needs a Developer ID Application certificate, and
this machine has only an Apple Development one. The release script runs end to end
otherwise: hardened runtime, entitlements, and a deep signature over the app, the 7-Zip
library and the Sparkle framework, all confirmed with `codesign --verify --deep --strict`.
Sparkle is embedded and starts, but no appcast is published, so there is nothing to find.
Quick Actions proper would need another app extension. The Quick Look ones show that a
hand-assembled bundle can carry them; for now the Services menu covers the same ground.

**Note on the dmg engine.** `DMGEngine` attaches images read-only through `hdiutil`
at a private mount root and treats the mounted filesystem as the archive, which is the
only way to read HFS+ and APFS images correctly. Mounts are cached per archive for the
life of a window and detached on close and on quit. Creation maps our 0-9 compression
scale onto UDRO, UDZO with a zlib level, and ULFO, with optional AES-256.

macOS 27 prints a deprecation warning for `hdiutil` and points at `diskutil image`.
The tool still works, and `diskutil image` does not exist on the older systems the app
supports, so the migration waits until the minimum version rises.

## 6. Open decisions (defaults chosen, change if you disagree)

- Default handler for `.dmg`: **off** by default (Finder's DiskImageMounter stays); user opts in.
- Sandbox/App Store: **no** for v1.
- Minimum macOS: **14 Sonoma**.
- Extract destination default: **same folder as archive**, smart folder **on**, move-to-trash **off**.
