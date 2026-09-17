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
| rar, rar5 | yes | yes, after a one-click download of RARLAB's tool |
| iso, cab, xar, pkg, cpio, deb, rpm, wim, lzh, arj, msi, chm | yes | no |
| dmg | yes, via hdiutil | yes, zlib or LZFSE, optional AES-256 |

Passwords are supported for zip (ZipCrypto and AES-256), 7z including encrypted
headers, rar, and encrypted disk images.

**RAR writing** needs RARLAB's own tool, which cannot be bundled with the app. Settings
has a Download RAR button that fetches the official macOS build, checks that it runs and
installs it under Application Support. An existing copy elsewhere can be chosen instead.
Reading RAR never needs it.

**Disk images** are attached read-only at a private mount point, so you see the real
filesystem rather than the UDIF container. The mount is held for as long as the window
is open and detached when it closes or the app quits. Symlinks, permissions and
extended attributes survive extraction, so the `/Applications` link that app images
ship with is copied as a link and never written through.

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

## Other things it does

- **Cloud files.** Archives in iCloud Drive, Google Drive or Dropbox are often
  placeholders with no data on disk. JustArc asks the provider to fetch one before
  reading it, shows a cancellable download panel, and names the provider if it fails.

- **Finder Services.** Compress, compress choosing a format, extract, and open, all from
  the Finder context menu.
- **Edited files go back in.** Open a file out of an archive, edit it in another app, and
  JustArc offers to update the archive when you switch back.
- **Split volumes.** Pick a preset in the Save panel or type a size such as `1.5g`.
- **Filename encodings.** Zip archives written before UTF-8 was common can be re-read as
  CP866, Shift JIS and the rest.
- **English and Russian.** The interface follows the system language.

## Debugging

The app takes file paths on the command line, which behave exactly like files opened
from Finder. Set `JUSTARC_VERBOSE=1` to mirror engine logging onto stderr:

```bash
JUSTARC_VERBOSE=1 ./build/JustArc.app/Contents/MacOS/JustArc ~/Downloads/thing.dmg
```

Engine logging also goes to the unified log under the `com.justarc.JustArc` subsystem.

After changing any message shown to a person, regenerate the translation files:

```bash
./Scripts/update-strings.py
```

It preserves existing translations, lists anything new that needs one, and refuses to
run if a message was assembled with `+`, because such a key cannot be extracted.

## Releasing

```bash
SIGN_IDENTITY="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=justarc \
  ./Scripts/release.sh 0.2.0
```

That builds, signs with the hardened runtime, packages a disk image laid out as an
installer, notarizes and staples. Create the notary profile once with
`xcrun notarytool store-credentials`. With no identity it signs ad-hoc, which is fine
locally and will not pass Gatekeeper anywhere else.

Updates go through Sparkle. Before the first release, generate a key pair with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys`, put the public key in `Info.plist`
as `SUPublicEDKey`, and publish an appcast at the `SUFeedURL`. The release script warns
when the key is missing, and Sparkle refuses to install an unsigned update.

## Known gaps

- Notarization is untested here, because this machine has only an Apple Development
  certificate. Everything up to it is verified: hardened runtime, entitlements, and a
  deep signature over the app, the 7-Zip helper and the Sparkle framework.
- No appcast is published yet, so Check for Updates has nothing to find.
- StuffIt and other legacy formats are not read. That needs XADMaster.
- Passwords reach 7-Zip and RAR as command line arguments, so they are briefly visible
  to other processes of the same user. Moving to an in-process 7-Zip library would fix
  this and is the main reason to do it.
- macOS 27 deprecates `hdiutil` in favour of `diskutil image`. It still works and is
  the only option on older systems, so the migration is deferred.
