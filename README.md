# JustArc

A fast archiver for macOS. Double-click an archive and it unpacks and gets out of
the way; open the app and you get a WinRAR-style window for browsing, editing and
building archives.

## What works today

**Quick Extract (double-click an archive)**
No main window, just a progress panel. The archive lands beside itself, a wrapper
folder is created only when the archive holds loose files, and the app quits when
the last job finishes. Encrypted archives prompt for a password, with an option to
remember it in the login keychain. Hold Option while opening to browse instead.

**Browser window**
Command strip, address row with an archive-wide filter, sortable file list with
Name, Size, Packed, Type, Modified and CRC32 columns, an optional folder tree, and
a two-pane status bar. A bare launch opens an empty archive you can drag files into
and then save. Double-click a file to open it, press Space for Quick Look, drag
entries out to Finder.

**Formats**

| | Read | Write |
|---|---|---|
| zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst | yes | yes |
| gz, bz2, xz, zst | yes | yes |
| rar, rar5 | yes | only with RARLAB's `rar` installed |
| iso, cab, xar, pkg, cpio, deb, rpm, wim, lzh, arj, msi, chm | yes | no |
| dmg | listed by format registry, engine not wired up yet | not yet |

Passwords are supported for zip (ZipCrypto and AES-256), 7z including encrypted
headers, and rar.

## Building

Xcode's toolchain is used through `DEVELOPER_DIR`, so no `sudo xcode-select` is
needed when only the Command Line Tools are active.

```bash
./Scripts/build-app.sh
```

That produces `build/JustArc.app`. For a release build, pass `release`.

Run the tests with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Layout

- `Sources/JustArcCore` — engine, models and safety checks. No AppKit, fully tested.
- `Sources/JustArc` — the AppKit app: launch routing, Quick Extract, browser window.
- `Vendor/7zz` — the 7-Zip binary, universal, under the GNU LGPL. Refresh it with
  `Scripts/fetch-7zz.sh`.

## Known gaps

- Disk images are recognised but `hdiutil` is not wired in yet, so `.dmg` cannot be
  browsed or created.
- Split volumes can be read but the Save panel does not offer a volume size yet.
- No code signing, notarization or updater. `build-app.sh` signs ad-hoc for local use.
