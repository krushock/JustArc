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
A sortable list with Name, Size, Packed, Type, Modified and CRC32 columns, under a
toolbar laid out like Disk Utility's, with a status bar along the bottom. An optional
sidebar lists recently used archives. A bare launch opens an empty archive you can drag
files into and then save; opening an archive while that window is still untouched
opens it in its place rather than leaving an empty window behind.

**Extract or open.** Double-clicking an archive in the Finder unpacks it, opens it in
a window, or asks, as chosen in Settings ▸ Extracting. Whatever that setting says,
these always open the archive in a window, for when you want to look inside or edit:

- dropping it on JustArc's Dock icon,
- right-clicking it in the Finder and choosing Services ▸ Open Archive in JustArc,
- opening it while a JustArc window is already up, or dropping it on an empty one,
- holding Option while opening it, which does the opposite of the setting.

Any other file dropped on the Dock icon starts a new archive. Recently used archives
are in File ▸ Open Recent and on the Dock icon's menu.

**File types.** Settings ▸ File Types lists each kind of archive with a menu of the
apps that can open it, so JustArc can be made the default for zip but not for rar, say,
or for everything at once. This is the same setting as Get Info ▸ Open With ▸ Change
All in the Finder, and macOS confirms each change with a dialog of its own.

**Files go in and come out by dragging.** Files and folders dropped anywhere in a
window are added to its archive, into the folder the list is showing; dropped on a
folder's row, or among the rows of an expanded one, they go into that folder, as in
the Finder. Add Files puts them in the folder being shown too. A window showing an
archive that cannot be changed refuses the drop. Files and folders drag out of the
list straight to the Finder.

Folders expand in place with a disclosure triangle, the way Finder's list view works,
and double-clicking one still navigates into it. An archive that wraps everything in a
single folder opens that folder for you. Space previews the selected file with Quick
Look, and Return opens it. The `__MACOSX` folder and `._` files that macOS adds to
the archives it makes are left out, both from the list and from what is extracted.

Dragging from empty space, or across any column but Name, draws a selection rectangle
the way the desktop does. Shift adds to the selection and Command toggles rows. Drag
past the top or bottom and the list scrolls. Dragging by a name still drags files out.

**The window is built from stock AppKit**, not from a skin. The commands live in an
`NSToolbar` with names beneath the icons, the sidebar is a sidebar split item, the
location shows in the window's subtitle, and the filter is a search toolbar item. That matters for more than tidiness: on macOS 26 and later the system draws
those components with Liquid Glass, the scroll edge effect and the grouped toolbar
shapes on its own. Nothing here paints glass by hand, so the app follows the system
as it changes rather than freezing one year's appearance. The minimum stays macOS 14,
where the same components render in that system's style.

**One thing makes or breaks this.** macOS decides whether an app gets the new design
from the SDK version stamped into its executable, not from the SDK it was compiled
against. SwiftPM compiles against the current SDK but stamps the deployment target in
its place, so the binary claimed the macOS 14 SDK and was shown the old flat toolbar
even on macOS 27. `build-app.sh` rewrites the stamp to the SDK actually used, with
`vtool`, and leaves the deployment target alone. Check it with:

```bash
otool -l build/JustArc.app/Contents/MacOS/JustArc | grep -A5 LC_BUILD_VERSION
```

The `sdk` line must match the installed SDK. If it shows the deployment target, the
window will look like an app from years ago.

To check the appearance without screen recording access, set `JUSTARC_SNAPSHOT` to a
path and the first window renders itself to a PNG and quits. It shows layout and the
glass controls faithfully; vibrant materials such as the sidebar's translucency and
source-list selection come out flat or black, so those still need a look on screen.

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
- `Tests/JustArcAppTests` — drives the app's real views: files dropped on each part of
  the window, files and folders dragged out, and the Settings panes.
- `Sources/SevenZipBridge` — a small C bridge over 7-Zip's format library, plus the
  vendored 7-Zip 25.01 source it compiles against. Archives are read and written in
  process; nothing runs as a subprocess, so passwords never appear in a command line.
- `Vendor/7z.so` — 7-Zip's format library, universal, under the GNU LGPL, copied into
  `Contents/Frameworks`. Rebuild it from the vendored source with
  `Scripts/build-7z-library.sh`.
- `Vendor/7zz` — the 7-Zip command-line tool. The app does not ship it; the tests use
  it to build fixtures independently of the code under test. Refresh it with
  `Scripts/fetch-7zz.sh`.

## Other things it does

- **Existing files and folders.** Extracting onto something already there asks what to
  do, once for the whole operation. A folder can be merged into, replaced, kept
  alongside or skipped; replacing moves the old one to the Trash so it stays
  recoverable. A file can be replaced, kept alongside or skipped. Settings can fix
  either answer.
- **Cloud files.** Archives in iCloud Drive, Google Drive or Dropbox are often
  placeholders with no data on disk. JustArc asks the provider to fetch one before
  reading it, shows a cancellable download panel, and names the provider if it fails.

- **Finder Services.** Compress, compress choosing a format, extract, and open, all from
  the Finder's right-click Services menu. Extract and open are offered for archives only.
- **Zip encryption.** The Save panel offers AES-256 or the older ZipCrypto, which is weak
  but opens in tools that never learned AES, Archive Utility among them.
- **Edited files go back in.** Open a file out of an archive, edit it in another app, and
  JustArc offers to update the archive when you switch back.
- **Split volumes.** Pick a preset in the Save panel or type a size such as `1.5g`.
- **Filename encodings.** Zip archives written before UTF-8 was common can be re-read as
  CP866, Shift JIS and the rest.
- **English and Russian.** The interface follows the system language.
- **Settings** is a standard tabbed settings window, and About is the system panel.

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

## What extraction promises

Archives are untrusted input, and the destination is the user's own data.

- A file, and a link, is made under a temporary name and moved into place only when
  it is whole. A damaged archive leaves whatever was there before exactly as it was,
  whichever overwrite rule was chosen, and one item that fails does not stop the
  others unless the disk itself has stopped taking writes.
- Cancelling puts the destination back as it was found. So does a password that is
  missing or wrong, so that the next attempt starts clean.
- An archive that holds both a file and a folder of one name, which a disk cannot,
  is extracted with one of them renamed rather than refused.
- Nothing is written outside the destination: not through `..`, an absolute path, or
  a symbolic link planted by an earlier entry.
- No symbolic link is left pointing outside the destination. Links are made last and
  then each is followed on disk to where it really leads, so one that only escapes
  in combination with another, made before or after it, is found and removed.
- A hard link is a second name for a file of the same archive, never for a file that
  merely has that name at the destination.
- A folder is never removed to make room for a file, and the folder being extracted
  into is never one of the things "replaced".
- setuid, setgid and sticky bits are not restored, and the user's umask applies.
- Sizes an archive declares are not trusted: a stream that expands without limit is
  stopped before the disk fills.

Each of these has a test built from an archive made to break it, in
`ExtractionSafetyTests` and `ReviewRegressionTests`.

## Known gaps

- Notarization is untested here, because this machine has only an Apple Development
  certificate. Everything up to it is verified: hardened runtime, entitlements, and a
  deep signature over the app, the 7-Zip library and the Sparkle framework.
- No appcast is published yet, so Check for Updates has nothing to find.
- StuffIt and other legacy formats are not read. That needs XADMaster.
- RARLAB's `rar` takes the password as a command line argument, so while a RAR archive
  is being written it is briefly visible to other processes of the same user. Every
  other format, and reading RAR, goes through the in-process 7-Zip library.
- 7-Zip reads Zstandard but cannot write it, so `.zst` and `.tar.zst` are read-only.
- LZ4 is not read: 7-Zip has no handler for it.
- A static library made on macOS (`.a` from `ar`) opens as a single symbol listing.
  macOS writes the BSD layout, with member names moved into the data, which 7-Zip
  does not parse. Libraries and `.deb` packages from Linux open normally.
- A file name that is not valid UTF-8 is decoded with the DOS code page that goes with
  the Mac's language (866 for Russian, 932 for Japanese, 437 otherwise), which is a
  guess. View ▸ Filename Encoding sets it for the archive in the window.
- Telling a drop on the Dock icon from a double-click relies on which process sent the
  open request. That is confirmed for requests from the command line; the Dock itself
  has not been tried, because nothing here can drive the pointer.
- Extended attributes and resource forks that macOS stores in `__MACOSX` and `._` files
  are skipped on extraction rather than applied to the extracted files.
- The RAR tools are checked against a SHA-256 before they are unpacked: one built
  into JustArc for the release it knows, otherwise the one Homebrew records for its
  `rar` cask. RARLAB publishes no checksums itself, so a release newer than both has
  nothing to be checked against; JustArc says so and installs it only if told to.
  The built-in hashes are Homebrew's; `RarIntegrationTests`, run with
  `JUSTARC_NETWORK_TESTS=1`, downloads both builds from rarlab.com and confirms them.
- Cancelling an extraction undoes it: new files and folders are removed, and files
  that were replaced or moved aside are put back. Two exceptions: a replaced file on
  a volume without hard links (exFAT, FAT), and one replaced while extracting a disk
  image, stay replaced.
- 7z and RAR give no way to tell a wrong password from damaged data. When nothing in
  the archive decodes, JustArc calls it a wrong password; once one encrypted file
  has decoded, later failures are reported as damage.
- The reason the system gives for a failed write ("No space left on device") is in
  English whatever the app's language; the sentence around it is translated.
- macOS 27 deprecates `hdiutil` in favour of `diskutil image`. It still works and is
  the only option on older systems, so the migration is deferred.
