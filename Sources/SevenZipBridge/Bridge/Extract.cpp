// Extract.cpp
//
// Extracting and testing. 7-Zip decides the order items are decoded in and asks this
// callback for somewhere to put each one.

#include "BridgeInternal.h"

#include "7zip/Common/FileStreams.h"

#include <copyfile.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
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

/// A folder's date and permissions, applied once nothing more is written into it.
struct PendingFolder {
    std::string path;
    bool hasTime = false;
    int64_t seconds = 0;
    int32_t nanoseconds = 0;
    bool hasMode = false;
    UInt32 mode = 0;
};

/// A tar hard link: a second name for a file stored earlier in the archive. The
/// item carries no data of its own, so it is made once that file is on disk.
struct PendingHardLink {
    std::string itemPath;
    std::string finalPath;
    std::string target;
};

enum class Failure {
    none,
    wrongPassword,
    dataError,
    unsupported,
    writeError,
    unsafePath,
};

/// Receives each item as 7-Zip decodes it.
///
/// A file is decoded into a temporary name beside its destination and only moved
/// into place once it has decoded correctly. Until then nothing that was already
/// there is touched, so a wrong password, a damaged archive or a cancel leaves the
/// destination as it was found, whichever overwrite rule is in force.
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
    /// True when an item was abandoned half-written, which without any other
    /// explanation means the disk refused the data.
    bool abandonedAnItem = false;

    /// Tidies up after 7-Zip returns, however it returned.
    void Finish();

private:
    // The item in flight.
    std::string itemPath;
    std::string finalPath;
    std::string temporaryPath;
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

    std::vector<PendingFolder> folders;
    std::vector<PendingHardLink> hardLinks;

    void Record(Failure kind, const std::string &detail) {
        if (failure != Failure::none) return;
        failure = kind;
        failurePath = itemPath;
        failureDetail = detail;
    }

    void AbandonInFlight();
    bool MakeWay(std::string &path);
    bool CommitFile();
    bool LinkStaysInside(const std::string &linkPath, const std::string &target);
    void CreateLink(const std::string &target);
    void CreateHardLinks();
};

Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64 size)) {
    progress.SetTotal(size);
    return progress.Report() ? S_OK : E_ABORT;
}

Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *value)) {
    if (value) progress.SetCompleted(*value);
    return progress.Report() ? S_OK : E_ABORT;
}

/// Drops a file that never finished decoding.
void ExtractCallback::AbandonInFlight() {
    if (fileStream) {
        fileSpec->Close();
        fileStream.Release();
        fileSpec = nullptr;
    }
    linkStream.Release();
    linkSpec = nullptr;
    if (!temporaryPath.empty()) {
        unlink(temporaryPath.c_str());
        temporaryPath.clear();
        abandonedAnItem = true;
    }
}

/// Applies the overwrite rule to a path that a link is about to be made at. Returns
/// false when the item should not be written, having recorded why if that is an error.
bool ExtractCallback::MakeWay(std::string &path) {
    if (!PathExists(path)) return true;
    switch (overwrite) {
        case SZOverwriteSkip:
            return false;
        case SZOverwriteRenameNew:
            path = UniquePath(path);
            return true;
        case SZOverwriteRenameExisting: {
            const std::string moved = UniquePath(path);
            if (rename(path.c_str(), moved.c_str()) != 0) {
                Record(Failure::writeError, std::string("could not rename the existing item: ") + std::strerror(errno));
                return false;
            }
            return true;
        }
        case SZOverwriteReplace:
            // A folder in the way of a file is never removed: that could take a
            // great deal of the user's data with it.
            if (IsDirectoryPath(path) && !IsSymlinkPath(path)) {
                Record(Failure::writeError, "a folder with the same name is in the way");
                return false;
            }
            if (unlink(path.c_str()) != 0) {
                Record(Failure::writeError, std::string("could not replace the existing file: ") + std::strerror(errno));
                return false;
            }
            return true;
    }
    return true;
}

/// Moves a fully decoded file from its temporary name to its real one.
bool ExtractCallback::CommitFile() {
    std::string target = finalPath;
    if (overwrite == SZOverwriteReplace) {
        // rename() replaces a file in one step, so there is no moment at which
        // neither the old file nor the new one exists.
        if (IsDirectoryPath(target) && !IsSymlinkPath(target)) {
            Record(Failure::writeError, "a folder with the same name is in the way");
            unlink(temporaryPath.c_str());
            return false;
        }
    } else if (!MakeWay(target)) {
        unlink(temporaryPath.c_str());
        return false;
    }
    if (rename(temporaryPath.c_str(), target.c_str()) != 0) {
        Record(Failure::writeError, std::string("could not move the file into place: ") + std::strerror(errno));
        unlink(temporaryPath.c_str());
        return false;
    }
    finalPath = target;
    return true;
}

Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askMode)) {
    *outStream = nullptr;
    AbandonInFlight();
    finalPath.clear();

    IInArchive *handle = archive->archive;
    itemPath = Narrow(ItemPath(archive, index));
    itemEncrypted = GetBoolProperty(handle, index, kpidEncrypted);
    progress.SetCurrent(itemPath);
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

    const std::string path = destination + "/" + relative;
    // Refused before anything is created: otherwise folders are made one inside the
    // other until the system gives up, leaving a chain too deep to delete easily.
    if (path.size() >= PATH_MAX - 64) {
        Record(Failure::writeError, "its path is longer than macOS allows");
        return E_ABORT;
    }
    const std::string parent = path.substr(0, path.find_last_of('/'));
    if (!MakeDirectories(parent)) {
        Record(Failure::writeError, std::string("could not create a folder: ") + std::strerror(errno));
        return E_ABORT;
    }

    if (isDirectory) {
        if (!MakeDirectories(path)) {
            Record(Failure::writeError, PathExists(path)
                   ? std::string("a file with the same name is in the way")
                   : std::string("could not create a folder: ") + std::strerror(errno));
            return E_ABORT;
        }
        PendingFolder folder;
        folder.path = path;
        folder.hasTime = hasTime;
        folder.seconds = seconds;
        folder.nanoseconds = nanoseconds;
        folder.hasMode = hasMode;
        folder.mode = mode;
        folders.push_back(folder);
        return S_OK;
    }

    UString hardLinkTarget;
    if (GetStringProperty(handle, index, kpidHardLink, hardLinkTarget) && !hardLinkTarget.IsEmpty()) {
        hardLinks.push_back({itemPath, path, Narrow(hardLinkTarget)});
        return S_OK;
    }

    if (PathExists(path)) {
        if (overwrite == SZOverwriteSkip) return S_OK;
        if (overwrite == SZOverwriteReplace && IsDirectoryPath(path) && !IsSymlinkPath(path)) {
            Record(Failure::writeError, "a folder with the same name is in the way");
            return E_ABORT;
        }
    }
    finalPath = path;

    if (itemIsLink) {
        linkSpec = new MemoryOutStream;
        linkStream = linkSpec;
        *outStream = linkStream;
        linkStream->AddRef();
        return S_OK;
    }

    char suffix[32];
    snprintf(suffix, sizeof(suffix), "%08x%08x", arc4random(), arc4random());
    temporaryPath = parent + "/.justarc-" + suffix + ".part";
    fileSpec = new COutFileStream;
    fileStream = fileSpec;
    if (!fileSpec->Create_NEW(temporaryPath.c_str())) {
        Record(Failure::writeError, std::string("could not create the file: ") + std::strerror(errno));
        fileStream.Release();
        fileSpec = nullptr;
        temporaryPath.clear();
        return E_ABORT;
    }
    *outStream = fileStream;
    fileStream->AddRef();
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) {
    return S_OK;
}

/// Whether a link at `linkPath` pointing at `target` resolves inside the destination.
///
/// The target is followed one component at a time. Climbing above the destination is
/// refused, and so is passing through anything that is already a symbolic link: an
/// earlier entry could have planted one, and what lies beyond it cannot be judged by
/// counting components.
bool ExtractCallback::LinkStaysInside(const std::string &linkPath, const std::string &target) {
    if (target.empty() || target[0] == '/' || target.find('\0') != std::string::npos) return false;

    const std::string linkDirectory = linkPath.substr(0, linkPath.find_last_of('/'));
    std::vector<std::string> stack;
    if (linkDirectory.size() > destination.size()) {
        const std::string relative = linkDirectory.substr(destination.size() + 1);
        size_t start = 0;
        while (start <= relative.size()) {
            const size_t slash = relative.find('/', start);
            const std::string part = relative.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
            if (!part.empty()) stack.push_back(part);
            if (slash == std::string::npos) break;
            start = slash + 1;
        }
    }

    size_t start = 0;
    while (start <= target.size()) {
        const size_t slash = target.find('/', start);
        const std::string part = target.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        if (part == "..") {
            if (stack.empty()) return false;
            stack.pop_back();
        } else if (!part.empty() && part != ".") {
            stack.push_back(part);
            std::string walked = destination;
            for (const std::string &component : stack) walked += "/" + component;
            if (IsSymlinkPath(walked)) return false;
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}

/// Creates a symbolic link, unless its target would lead outside the destination.
/// 7-Zip refuses such links by default for the same reason: a later entry could be
/// written through one and land anywhere on disk.
void ExtractCallback::CreateLink(const std::string &target) {
    if (!LinkStaysInside(finalPath, target)) {
        summary.linksRefused++;
        return;
    }
    std::string path = finalPath;
    if (!MakeWay(path)) return;
    if (symlink(target.c_str(), path.c_str()) != 0) {
        Record(Failure::writeError, std::string("could not create a link: ") + std::strerror(errno));
        return;
    }
    summary.filesProcessed++;
}

void ExtractCallback::CreateHardLinks() {
    for (const PendingHardLink &pending : hardLinks) {
        itemPath = pending.itemPath;
        std::string relative;
        if (!SanitizePath(pending.target, relative) || relative.empty()) {
            summary.linksRefused++;
            continue;
        }
        if (flatten) {
            const size_t slash = relative.find_last_of('/');
            if (slash != std::string::npos) relative = relative.substr(slash + 1);
        }
        const std::string source = destination + "/" + relative;
        struct stat info;
        if (!NoLinkInParents(destination, relative) || lstat(source.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) {
            // The file it names was not extracted, or is not a plain file.
            summary.linksRefused++;
            continue;
        }
        std::string path = pending.finalPath;
        if (!MakeWay(path)) continue;
        if (link(source.c_str(), path.c_str()) != 0
            && copyfile(source.c_str(), path.c_str(), nullptr, COPYFILE_ALL) != 0) {
            Record(Failure::writeError, std::string("could not create a hard link: ") + std::strerror(errno));
            continue;
        }
        summary.filesProcessed++;
    }
    hardLinks.clear();
}

void ExtractCallback::Finish() {
    AbandonInFlight();
    if (testOnly) return;
    if (failure == Failure::none && !progress.Cancelled()) CreateHardLinks();

    // Folders get their dates and permissions last, deepest first, now that nothing
    // more is written into them. The owner always keeps access to what was extracted.
    for (auto it = folders.rbegin(); it != folders.rend(); ++it) {
        mode_t permissions = 0;
        if (it->hasMode && UsablePermissions(it->mode, permissions)) {
            chmod(it->path.c_str(), permissions | 0700);
        }
        if (it->hasTime) {
            timespec times[2];
            times[0].tv_sec = it->seconds;
            times[0].tv_nsec = it->nanoseconds;
            times[1] = times[0];
            utimensat(AT_FDCWD, it->path.c_str(), times, AT_SYMLINK_NOFOLLOW);
        }
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

        if (result != kOK || closed != S_OK) {
            // A half-written or wrongly decrypted file is worse than no file, and
            // whatever was there before has not been touched.
            unlink(temporaryPath.c_str());
        } else if (CommitFile()) {
            mode_t permissions = 0;
            if (hasMode && UsablePermissions(mode, permissions)) chmod(finalPath.c_str(), permissions);
            summary.filesProcessed++;
        }
        temporaryPath.clear();
    } else if (linkStream) {
        const std::string target = linkTargetFromHeader.empty() ? linkSpec->data : linkTargetFromHeader;
        linkStream.Release();
        linkSpec = nullptr;
        if (result == kOK) CreateLink(target);
    } else if (result == kOK && !extracting) {
        summary.filesProcessed++;  // testing
    }

    // Every further item would fail the same way with the wrong password, and a disk
    // that refuses one file will refuse the next.
    if (failure == Failure::wrongPassword || failure == Failure::writeError) return E_ABORT;
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

    callbackSpec->Finish();

    if (summary) {
        *summary = callbackSpec->summary;
        summary->bytesProcessed = callbackSpec->progress.Completed();
    }

    if (callbackSpec->progress.Cancelled()) {
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
        if (callbackSpec->abandonedAnItem) {
            // 7-Zip stopped partway through writing a file and named no cause of its
            // own, which is what a full or failing disk looks like from here.
            Fail(error, SZStatusWriteError, "The disk could not take the file being written. It may be full.");
            return SZStatusWriteError;
        }
        Fail(error, SZStatusFailed, DescribeHRESULT(result));
        return SZStatusFailed;
    }
    return SZStatusOK;
}
