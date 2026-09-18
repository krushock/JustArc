// BridgeInternal.h
//
// Shared pieces of the bridge. Only the .cpp files in this folder include it; Swift
// sees nothing but SevenZipBridge.h.

#ifndef SEVENZIP_BRIDGE_INTERNAL_H
#define SEVENZIP_BRIDGE_INTERNAL_H

#include "Common/Common.h"
#include "Common/MyWindows.h"
#include "Common/MyString.h"
#include "Common/MyCom.h"
#include "Common/UTFConvert.h"

#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/IPassword.h"

#include "SevenZipBridge.h"

#include <string>
#include <vector>

namespace SZBridge {

// MARK: - Text

/// UTF-8 in, 7-Zip's wide string out.
UString Wide(const char *utf8);
/// 7-Zip's wide string in, UTF-8 out.
std::string Narrow(const UString &wide);
std::string Narrow(const wchar_t *wide);

bool EqualsIgnoringCase(const UString &a, const UString &b);

// MARK: - Errors

void Fail(SZError *error, SZStatus status, const std::string &message);
std::string DescribeHRESULT(HRESULT result);

// MARK: - The loaded library

struct Handler {
    UString name;
    GUID classID;
    /// Space-separated, lowercase.
    UString extensions;
    /// Parallel to `extensions`: what the extension turns into for the item inside,
    /// "*" meaning simply drop it. Used for naming the payload of gzip and friends.
    UString addExtensions;
    std::vector<std::vector<Byte>> signatures;
    UInt32 signatureOffset = 0;
    Func_IsArc isArc = nullptr;
    bool canWrite = false;
};

struct Library {
    void *module = nullptr;
    Func_CreateObject createObject = nullptr;
    std::vector<Handler> handlers;
};

/// NULL until sz_load has succeeded.
Library *LoadedLibrary();
const Handler *FindHandler(const UString &name);

// MARK: - An opened archive

}  // namespace SZBridge

struct SZArchive {
    CMyComPtr<IInArchive> archive;
    /// For an archive split into volumes, 7-Zip's "Split" handler, which joins the
    /// volumes into the one stream `archive` reads. Kept open for as long as it is.
    CMyComPtr<IInArchive> volumes;
    const SZBridge::Handler *handler = nullptr;
    std::string path;
    std::string formatName;
    std::string comment;
    bool hasComment = false;
    bool headersEncrypted = false;
    UString password;
    bool hasPassword = false;
    std::string defaultItemName;
    // Storage behind the pointers handed out by sz_item.
    std::string itemPath;
    std::string itemMethod;
};

namespace SZBridge {

bool GetBoolProperty(IInArchive *archive, UInt32 index, PROPID id, bool fallback = false);
bool GetUInt64Property(IInArchive *archive, UInt32 index, PROPID id, UInt64 &value);
bool GetUInt32Property(IInArchive *archive, UInt32 index, PROPID id, UInt32 &value);
bool GetStringProperty(IInArchive *archive, UInt32 index, PROPID id, UString &value);

/// The item's path as the archive stores it, or the archive's own name less its
/// extension when a single-stream format such as gzip stores none.
UString ItemPath(SZArchive *archive, UInt32 index);

/// Folders, symbolic links and the Unix mode, however the format expresses them.
bool ItemIsDirectory(IInArchive *archive, UInt32 index);
bool ItemPosixMode(IInArchive *archive, UInt32 index, UInt32 &mode);
bool ItemIsSymlink(IInArchive *archive, UInt32 index);

/// Seconds and nanoseconds since 1970 from a 7-Zip FILETIME property.
bool ItemModified(IInArchive *archive, UInt32 index, int64_t &seconds, int32_t &nanoseconds);

// MARK: - Paths

/// Turns an archive path into a relative path that stays inside the destination.
/// Leading slashes and "." components are dropped, as tar and 7-Zip do; a ".."
/// component makes the whole path unsafe and the function returns false.
bool SanitizePath(const std::string &raw, std::string &safe);

/// A free name beside `path`: "name 2.ext", "name 3.ext" and so on, matching what
/// the Finder and the rest of JustArc do.
std::string UniquePath(const std::string &path);

bool PathExists(const std::string &path);           // without following links
bool IsDirectoryPath(const std::string &path);      // following links
bool IsSymlinkPath(const std::string &path);

/// True when no component of `relative`, below `root`, is a symbolic link. Writing
/// through a link planted by an earlier entry is the classic way an archive escapes.
bool NoLinkInParents(const std::string &root, const std::string &relative);

/// Creates every folder in `path`.
bool MakeDirectories(const std::string &path);

// MARK: - Progress

struct Progress {
    SZProgressCallback callback = nullptr;
    void *context = nullptr;
    UInt64 total = 0;
    UInt64 completed = 0;
    std::string current;
    bool cancelled = false;

    /// Returns false once the caller has asked to cancel.
    bool Report();
};

}  // namespace SZBridge

#endif
