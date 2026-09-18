// Extract.cpp
//
// Extracting and testing. 7-Zip decides the order items are decoded in and asks this
// callback for somewhere to put each one.

#include "BridgeInternal.h"

#include "7zip/Common/FileStreams.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>

using namespace NWindows;
using namespace SZBridge;

namespace {

/// Collects a symbolic link's target, which zip and 7z store as the item's data.
class MemoryOutStream Z7_final:
    public ISequentialOutStream,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_1(ISequentialOutStream)
public:
    std::string data;
};

Z7_COM7F_IMF(MemoryOutStream::Write(const void *bytes, UInt32 size, UInt32 *processed)) {
    // A link target is a path; anything past a few kilobytes is not one.
    if (data.size() + size > 64 * 1024) return E_FAIL;
    data.append(static_cast<const char *>(bytes), size);
    if (processed) *processed = size;
    return S_OK;
}

struct PendingTime {
    std::string path;
    int64_t seconds;
    int32_t nanoseconds;
};

enum class Failure {
    none,
    wrongPassword,
    dataError,
    unsupported,
    writeError,
    unsafePath,
};

class ExtractCallback Z7_final:
    public IArchiveExtractCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)

public:
    SZArchive *archive = nullptr;
    std::string destination;
    SZOverwrite overwrite = SZOverwriteRenameNew;
    bool flatten = false;
    bool testOnly = false;
    UString password;
    bool hasPassword = false;

    Progress progress;
    SZExtractSummary summary {};

    bool passwordRequested = false;
    Failure failure = Failure::none;
    std::string failurePath;
    std::string failureDetail;

    std::vector<PendingTime> folderTimes;

private:
    // The item in flight.
    std::string itemPath;
    std::string diskPath;
    bool itemEncrypted = false;
    bool itemIsLink = false;
    std::string linkTargetFromHeader;
    bool hasMode = false;
    UInt32 mode = 0;
    bool hasTime = false;
    int64_t seconds = 0;
    int32_t nanoseconds = 0;
    bool extracting = false;

    COutFileStream *fileSpec = nullptr;
    CMyComPtr<ISequentialOutStream> fileStream;
    MemoryOutStream *linkSpec = nullptr;
    CMyComPtr<ISequentialOutStream> linkStream;

    void Record(Failure kind, const std::string &detail) {
        if (failure != Failure::none) return;
        failure = kind;
        failurePath = itemPath;
        failureDetail = detail;
    }

    HRESULT PrepareDestination(std::string &path);
    void CreateLink(const std::string &target);
};

Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64 size)) {
    progress.total = size;
    return progress.Report() ? S_OK : E_ABORT;
}

Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *value)) {
    if (value) progress.completed = *value;
    return progress.Report() ? S_OK : E_ABORT;
}

/// Applies the overwrite rule to a path that is about to be written. Leaves `path`
/// empty when the item should be skipped.
HRESULT ExtractCallback::PrepareDestination(std::string &path) {
    if (!PathExists(path)) return S_OK;
    switch (overwrite) {
        case SZOverwriteSkip:
            path.clear();
            return S_OK;
        case SZOverwriteRenameNew:
            path = UniquePath(path);
            return S_OK;
        case SZOverwriteRenameExisting: {
            const std::string moved = UniquePath(path);
            if (rename(path.c_str(), moved.c_str()) != 0) {
                Record(Failure::writeError, std::string("could not rename the existing item: ") + std::strerror(errno));
                return E_ABORT;
            }
            return S_OK;
        }
        case SZOverwriteReplace:
            // A folder in the way of a file is never removed: that could take a
            // great deal of the user's data with it.
            if (IsDirectoryPath(path) && !IsSymlinkPath(path)) {
                Record(Failure::writeError, "a folder with the same name is in the way");
                return E_ABORT;
            }
            if (unlink(path.c_str()) != 0) {
                Record(Failure::writeError, std::string("could not replace the existing file: ") + std::strerror(errno));
                return E_ABORT;
            }
            return S_OK;
    }
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askMode)) {
    *outStream = nullptr;
    fileStream.Release();
    fileSpec = nullptr;
    linkStream.Release();
    linkSpec = nullptr;
    diskPath.clear();

    IInArchive *handle = archive->archive;
    itemPath = Narrow(ItemPath(archive, index));
    itemEncrypted = GetBoolProperty(handle, index, kpidEncrypted);
    progress.current = itemPath;
    extracting = askMode == NArchive::NExtract::NAskMode::kExtract;
    if (!extracting) return S_OK;

    std::string relative;
    if (!SanitizePath(itemPath, relative)) {
        Record(Failure::unsafePath, "");
        return E_ABORT;
    }
    if (relative.empty()) return S_OK;

    const bool isDirectory = ItemIsDirectory(handle, index);
    itemIsLink = !isDirectory && ItemIsSymlink(handle, index);
    linkTargetFromHeader.clear();
    if (itemIsLink) {
        UString header;
        if (GetStringProperty(handle, index, kpidSymLink, header)) linkTargetFromHeader = Narrow(header);
    }
    hasMode = ItemPosixMode(handle, index, mode);
    hasTime = ItemModified(handle, index, seconds, nanoseconds);

    if (flatten) {
        // Folders have no place in a flat extraction; their files still arrive.
        if (isDirectory) return S_OK;
        const size_t slash = relative.find_last_of('/');
        if (slash != std::string::npos) relative = relative.substr(slash + 1);
    }

    if (!NoLinkInParents(destination, relative)) {
        Record(Failure::unsafePath, "");
        return E_ABORT;
    }

    std::string path = destination + "/" + relative;
    const size_t slash = path.find_last_of('/');
    if (!MakeDirectories(path.substr(0, slash))) {
        Record(Failure::writeError, std::string("could not create a folder: ") + std::strerror(errno));
        return E_ABORT;
    }

    if (isDirectory) {
        if (!MakeDirectories(path)) {
            Record(Failure::writeError, std::string("could not create a folder: ") + std::strerror(errno));
            return E_ABORT;
        }
        // Writing files into a folder changes its date, so dates are set at the end.
        if (hasTime) folderTimes.push_back({path, seconds, nanoseconds});
        return S_OK;
    }

    RINOK(PrepareDestination(path))
    if (path.empty()) return S_OK;  // skipped
    diskPath = path;

    if (itemIsLink) {
        linkSpec = new MemoryOutStream;
        linkStream = linkSpec;
        *outStream = linkStream;
        linkStream->AddRef();
        return S_OK;
    }

    fileSpec = new COutFileStream;
    fileStream = fileSpec;
    if (!fileSpec->Create_NEW(path.c_str())) {
        Record(Failure::writeError, std::string("could not create the file: ") + std::strerror(errno));
        fileStream.Release();
        fileSpec = nullptr;
        return E_ABORT;
    }
    *outStream = fileStream;
    fileStream->AddRef();
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) {
    return S_OK;
}

/// Creates a symbolic link, unless its target would lead outside the destination.
/// 7-Zip refuses such links by default for the same reason: a later entry could be
/// written through one and land anywhere on disk.
void ExtractCallback::CreateLink(const std::string &target) {
    if (target.empty() || target[0] == '/') {
        summary.linksRefused++;
        return;
    }
    std::string linkDirectory = diskPath.substr(0, diskPath.find_last_of('/'));
    std::string relativeDirectory = linkDirectory.size() > destination.size()
        ? linkDirectory.substr(destination.size() + 1) : "";
    std::string combined = relativeDirectory.empty() ? target : relativeDirectory + "/" + target;

    // Walk the combined path, refusing it if ".." ever climbs above the destination.
    int depth = 0;
    size_t start = 0;
    while (start <= combined.size()) {
        const size_t slash = combined.find('/', start);
        const std::string part = combined.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        if (part == "..") depth--;
        else if (!part.empty() && part != ".") depth++;
        if (depth < 0) {
            summary.linksRefused++;
            return;
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }

    if (symlink(target.c_str(), diskPath.c_str()) != 0) {
        Record(Failure::writeError, std::string("could not create a link: ") + std::strerror(errno));
    }
}

Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) {
    using namespace NArchive::NExtract::NOperationResult;

    if (result != kOK) {
        // With the wrong key, most formats report garbage data rather than naming the
        // password, so on an encrypted item that is what it almost always means.
        if (result == kWrongPassword || (itemEncrypted && (result == kDataError || result == kCRCError))) {
            Record(Failure::wrongPassword, "");
        } else if (result == kUnsupportedMethod) {
            Record(Failure::unsupported, "it uses a compression method 7-Zip cannot decode");
        } else {
            const char *reason = "the data is damaged";
            switch (result) {
                case kCRCError: reason = "its checksum does not match"; break;
                case kUnexpectedEnd: reason = "the archive ends too soon"; break;
                case kHeadersError: reason = "the archive's headers are damaged"; break;
                case kUnavailable: reason = "part of its data is missing"; break;
                default: break;
            }
            Record(Failure::dataError, reason);
        }
    }

    if (fileStream) {
        if (hasTime) {
            timespec time;
            time.tv_sec = seconds;
            time.tv_nsec = nanoseconds;
            fileSpec->SetMTime(&time);
        }
        const HRESULT closed = fileSpec->Close();
        fileStream.Release();
        fileSpec = nullptr;
        if (closed != S_OK) Record(Failure::writeError, "could not finish writing the file");
        if (result != kOK && !diskPath.empty()) {
            // A half-written or wrongly decrypted file is worse than no file.
            unlink(diskPath.c_str());
        } else if (hasMode && !diskPath.empty()) {
            chmod(diskPath.c_str(), (mode_t)(mode & 07777));
        }
        if (result == kOK) {
            summary.filesProcessed++;
        }
    } else if (linkStream) {
        const std::string target = linkTargetFromHeader.empty() ? linkSpec->data : linkTargetFromHeader;
        linkStream.Release();
        linkSpec = nullptr;
        if (result == kOK) {
            CreateLink(target);
            summary.filesProcessed++;
        }
    } else if (result == kOK && !extracting) {
        summary.filesProcessed++;  // testing
    }
    return progress.Report() ? S_OK : E_ABORT;
}

Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *result)) {
    passwordRequested = true;
    if (!hasPassword) return E_ABORT;
    return StringToBstr(password, result);
}

}  // namespace

extern "C" SZStatus sz_extract(SZArchive *archive, const uint32_t *indices, uint32_t count,
                               const SZExtractOptions *options,
                               SZProgressCallback progress, void *context,
                               SZExtractSummary *summary, SZError *error) {
    if (!archive || !options) {
        Fail(error, SZStatusFailed, "Nothing to extract from.");
        return SZStatusFailed;
    }

    auto *callbackSpec = new ExtractCallback;
    CMyComPtr<IArchiveExtractCallback> callback = callbackSpec;
    callbackSpec->archive = archive;
    callbackSpec->testOnly = options->testOnly;
    callbackSpec->flatten = options->flatten;
    callbackSpec->overwrite = options->overwrite;
    callbackSpec->progress.callback = progress;
    callbackSpec->progress.context = context;

    // A password supplied now wins; otherwise the one the archive was opened with.
    if (options->password && options->password[0]) {
        callbackSpec->password = Wide(options->password);
        callbackSpec->hasPassword = true;
    } else if (archive->hasPassword) {
        callbackSpec->password = archive->password;
        callbackSpec->hasPassword = true;
    }

    if (!options->testOnly) {
        std::string destination = options->destination ? options->destination : "";
        while (destination.size() > 1 && destination.back() == '/') destination.pop_back();
        if (destination.empty() || !MakeDirectories(destination)) {
            Fail(error, SZStatusWriteError, "The destination folder could not be created.");
            return SZStatusWriteError;
        }
        callbackSpec->destination = destination;
    }

    // 7-Zip requires the indices in ascending order, without duplicates.
    std::vector<UInt32> sorted;
    if (indices) {
        sorted.assign(indices, indices + count);
        std::sort(sorted.begin(), sorted.end());
        sorted.erase(std::unique(sorted.begin(), sorted.end()), sorted.end());
    }

    const HRESULT result = archive->archive->Extract(
        indices ? sorted.data() : nullptr,
        indices ? (UInt32)sorted.size() : (UInt32)(Int32)-1,
        options->testOnly ? 1 : 0,
        callback);

    // Folders get their dates last, deepest first, now nothing more is written into them.
    for (auto it = callbackSpec->folderTimes.rbegin(); it != callbackSpec->folderTimes.rend(); ++it) {
        timespec times[2];
        times[0].tv_sec = it->seconds;
        times[0].tv_nsec = it->nanoseconds;
        times[1] = times[0];
        utimensat(AT_FDCWD, it->path.c_str(), times, AT_SYMLINK_NOFOLLOW);
    }

    if (summary) {
        *summary = callbackSpec->summary;
        summary->bytesProcessed = callbackSpec->progress.completed;
    }

    if (callbackSpec->progress.cancelled) {
        Fail(error, SZStatusCancelled, "The operation was cancelled.");
        return SZStatusCancelled;
    }

    switch (callbackSpec->failure) {
        case Failure::unsafePath:
            Fail(error, SZStatusUnsafePath, callbackSpec->failurePath);
            return SZStatusUnsafePath;
        case Failure::wrongPassword:
            Fail(error, SZStatusWrongPassword, "The password is incorrect.");
            return SZStatusWrongPassword;
        case Failure::writeError:
            Fail(error, SZStatusWriteError, callbackSpec->failurePath + ": " + callbackSpec->failureDetail);
            return SZStatusWriteError;
        default:
            break;
    }

    if (callbackSpec->passwordRequested && !callbackSpec->hasPassword) {
        Fail(error, SZStatusPasswordRequired, "This archive is password protected.");
        return SZStatusPasswordRequired;
    }

    if (callbackSpec->failure == Failure::unsupported) {
        Fail(error, SZStatusUnsupported, callbackSpec->failurePath + ": " + callbackSpec->failureDetail);
        return SZStatusUnsupported;
    }
    if (callbackSpec->failure == Failure::dataError) {
        Fail(error, SZStatusDataError, callbackSpec->failurePath + ": " + callbackSpec->failureDetail);
        return SZStatusDataError;
    }

    if (result != S_OK) {
        Fail(error, SZStatusFailed, DescribeHRESULT(result));
        return SZStatusFailed;
    }
    return SZStatusOK;
}
