# Licence

This package builds `libSevenZipBridge.dylib`, the library through which JustArc
reads and writes archives. It holds two things:

- **7-Zip's own sources**, in `Sources/SevenZipBridge/7zip`, by Igor Pavlov,
  unchanged. They are under the GNU Lesser General Public License, version 2.1 or
  later, with the additions described in `Sources/SevenZipBridge/7zip/DOC/License.txt`.
- **The bridge** over them, in `Sources/SevenZipBridge/Bridge` and
  `Sources/SevenZipBridge/include`, written for JustArc. Compiled into one library
  with 7-Zip's code, it is a work based on 7-Zip, and is offered under the same
  terms: the GNU Lesser General Public License, version 2.1 or later.

The library is loaded by JustArc at run time and can be replaced by one built from
modified sources: build this package, and put the resulting
`libSevenZipBridge.dylib` in `JustArc.app/Contents/Frameworks` and
`JustArc.app/Contents/PlugIns/JustArcQuickLook.appex/Contents/Frameworks`, signed
as the rest of the app is. 7-Zip's format library, `7z.so`, built from the same
sources by `Scripts/build-7z-library.sh`, is replaced the same way.

None of 7-Zip's code is compiled into JustArc's own executables, so the terms
above do not reach them.
