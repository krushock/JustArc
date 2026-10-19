# Contributing to JustArc

Thank you for wanting to help. Bug reports, fixes and translations are all welcome.

## Before you start

- Build and test as the README describes: `swift test` must pass, and
  `Scripts/update-strings.py` must be run after changing any message shown to a
  person.
- Write code that reads like the code around it: its naming, its comments, and the
  way it says what it does.
- Keep a change to one thing, with a commit message that says what changed and why.

## The terms of a contribution

JustArc is licensed under the GNU General Public License, version 3 or later, and so
is everything contributed to it.

By submitting a contribution you also agree that the maintainer, KruShock, may
distribute it as part of JustArc through channels whose own terms sit awkwardly
with the GPL, the Mac App Store above all. This permission is only so that JustArc
itself can be offered there; the code stays under the GPL for everyone else, you
keep the copyright in what you wrote, and you remain free to use it however you
like.

Changes to the bridge in `Packages/SevenZipBridge` are part of a library built with
7-Zip's code, and are contributed under the GNU LGPL 2.1 or later, as that library is.
