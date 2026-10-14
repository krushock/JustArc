# JustArc Privacy

JustArc is an archiver that works on your Mac. It does not collect, store or send
anything about you or about the files you open, extract or create, and it contains no
analytics, crash reporting, advertising or tracking of any kind.

## When JustArc connects to the internet

- **Update checks.** Once a day, if you allowed it when JustArc asked or in
  Settings ▸ General, JustArc asks `justarc.app` whether there is a newer version.
  The request carries the name and version of JustArc and the version of the Sparkle
  updater, and, like any request on the internet, your IP address. Nothing else is
  sent. You can turn this off at any time, and Check for Updates still works when
  you choose it.
- **RAR's tools.** Only when you choose Download RAR in Settings ▸ RAR, JustArc
  downloads RARLAB's tools from `rarlab.com` and checks them against the record of
  their checksums kept by Homebrew at `formulae.brew.sh`. Both sites see the request,
  as any website would.

JustArc makes no other connections. Opening an archive in iCloud Drive, Google Drive
or another cloud folder asks macOS to fetch it, which is between you and that
provider.

## What stays on your Mac

- Archive passwords, only when you tick "Remember", in your login keychain. They are
  not synced and can be removed in Keychain Access.
- Your settings and the list of recently opened archives, in JustArc's preferences.
- The system log notes what JustArc did, such as how many items an archive held. The
  names of your files and folders are kept private in it.

## Contact

Questions about privacy: the address on justarc.app.
