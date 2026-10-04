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
#include <map>
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

/// One thing done to the destination, kept so it can be undone if the user cancels.
struct Step {
    enum Kind {
        /// `first` did not exist before and was created.
        created,
        /// `first` was renamed to `second` to make room.
        movedAside,
        /// `first` was replaced; `second` is a hidden copy of what it used to be.
        replaced,
        /// The folder `first` was created.
        createdFolder,
    } kind;
    std::string first;
    std::string second;
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
/// there is touched, so a wrong password or a damaged archive leaves the files it
/// could not produce as they were, whichever overwrite rule is in force.
///
/// Everything that is done is also written down, and a cancel undoes it in reverse:
/// new files and folders are removed, files moved aside are moved back, and replaced
/// files are restored from the copy kept until the end.
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
    std::vector<Step> journal;
    /// Folders that could not be made where the archive wanted them, because a file
    /// of that name is there, and where they went instead. Keyed by the path wanted.
    std::map<std::string, std::string> redirected;
    /// True once an encrypted item has decoded, which proves the password.
    bool passwordProven = false;
    /// True when the format checks the password itself before decoding, so that a
    /// data error on this item means damage and not a wrong password.
    bool itemVerifiesPassword = false;

    void Record(Failure kind, const std::string &detail) {
        if (failure != Failure::none) return;
        failure = kind;
        failurePath = itemPath;
        failureDetail = detail;
    }

    void AbandonInFlight();
    std::string PlaceFolder(const std::string &relative);
    std::string HiddenSibling(const std::string &path, const char *suffix);
    void Rollback();
    void DiscardBackups();
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

/// A name beside `path` that the Finder does not show, for work in progress.
std::string ExtractCallback::HiddenSibling(const std::string &path, const char *suffix) {
    char random[32];
    snprintf(random, sizeof(random), "%08x%08x", arc4random(), arc4random());
    return path.substr(0, path.find_last_of('/')) + "/.justarc-" + random + suffix;
}

/// Makes sure the folder at `relative`, a path under the destination, exists, and
/// returns where it really is. Empty when it could not be made.
///
/// Where a file already has the name a folder needs, the folder is made beside it
/// under a free name and everything addressed to it follows. An archive can hold both
/// "name" and "name/child"; a disk cannot, and losing either would be worse than
/// renaming one.
std::string ExtractCallback::PlaceFolder(const std::string &relative) {
    std::string wanted = destination;
    std::string actual = destination;
    size_t start = 0;
    while (start < relative.size()) {
        const size_t slash = relative.find('/', start);
        const std::string part = relative.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        start = slash == std::string::npos ? relative.size() : slash + 1;
        if (part.empty()) continue;

        wanted += "/" + part;
        const auto known = redirected.find(wanted);
        if (known != redirected.end()) {
            actual = known->second;
            continue;
        }

        std::string candidate = actual + "/" + part;
        struct stat info;
        if (lstat(candidate.c_str(), &info) == 0) {
            if (S_ISDIR(info.st_mode)) {
                actual = candidate;
                continue;
            }
            if (S_ISLNK(info.st_mode)) {
                // Writing through a link could land anywhere on disk.
                Record(Failure::unsafePath, "");
                return "";
            }
            candidate = UniquePath(candidate);
            redirected[wanted] = candidate;
        }
        if (mkdir(candidate.c_str(), 0755) != 0) {
            Record(Failure::writeError, std::string("could not create a folder: ") + std::strerror(errno));
            return "";
        }
        journal.push_back({Step::createdFolder, candidate, ""});
        actual = candidate;
    }
    return actual;
}

/// Applies the overwrite rule to a path that a link is about to be made at. Returns
/// false when the item should not be written, having recorded why if that is an error.
bool ExtractCallback::MakeWay(std::string &path) {
    if (!PathExists(path)) return true;
    // A folder in the way is never removed or moved: that could take a great deal of
    // the user's data with it. The new item goes beside it instead.
    if (IsDirectoryPath(path) && !IsSymlinkPath(path)) {
        if (overwrite == SZOverwriteSkip) return false;
        path = UniquePath(path);
        return true;
    }
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
            journal.push_back({Step::movedAside, path, moved});
            return true;
        }
        case SZOverwriteReplace: {
            // Set aside rather than deleted, so a cancel can put it back.
            const std::string backup = HiddenSibling(path, ".bak");
            if (rename(path.c_str(), backup.c_str()) != 0) {
                Record(Failure::writeError, std::string("could not replace the existing file: ") + std::strerror(errno));
                return false;
            }
            journal.push_back({Step::replaced, path, backup});
            return true;
        }
    }
    return true;
}

/// Moves a fully decoded file from its temporary name to its real one.
bool ExtractCallback::CommitFile() {
    std::string target = finalPath;
    const bool replacingFile = overwrite == SZOverwriteReplace && PathExists(target)
        && !(IsDirectoryPath(target) && !IsSymlinkPath(target));
    if (replacingFile) {
        // rename() replaces a file in one step, so there is no moment at which neither
        // the old file nor the new one exists. A second name for the old file is made
        // first, so that a cancel can bring it back; where the volume cannot do that,
        // the replacement simply cannot be undone.
        const std::string backup = HiddenSibling(target, ".bak");
        if (linkat(AT_FDCWD, target.c_str(), AT_FDCWD, backup.c_str(), 0) == 0) {
            journal.push_back({Step::replaced, target, backup});
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
    if (!replacingFile) journal.push_back({Step::created, target, ""});
    finalPath = target;
    return true;
}

/// Undoes everything done so far, newest first.
void ExtractCallback::Rollback() {
    for (auto step = journal.rbegin(); step != journal.rend(); ++step) {
        switch (step->kind) {
            case Step::created:
                unlink(step->first.c_str());
                break;
            case Step::movedAside:
                rename(step->second.c_str(), step->first.c_str());
                break;
            case Step::replaced:
                rename(step->second.c_str(), step->first.c_str());
                break;
            case Step::createdFolder:
                // Fails, rightly, if something else has since been put in it.
                rmdir(step->first.c_str());
                break;
        }
    }
    journal.clear();
    folders.clear();
}

/// Drops the copies kept of replaced files, once they can no longer be wanted.
void ExtractCallback::DiscardBackups() {
    for (const Step &step : journal) {
        if (step.kind == Step::replaced) unlink(step.second.c_str());
    }
    journal.clear();
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

    // Zip checks an AES password before decoding, so with one accepted, a failure
    // further on is damage. Other formats only find out by decoding.
    itemVerifiesPassword = false;
    if (itemEncrypted && EqualsIgnoringCase(archive->handler->name, UString(L"zip"))) {
        UString method;
        if (GetStringProperty(handle, index, kpidMethod, method)) {
            itemVerifiesPassword = method.Find(L"AES") >= 0;
        }
    }
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

    // Refused before anything is created: otherwise folders are made one inside the
    // other until the system gives up, leaving a chain too deep to delete easily.
    if (destination.size() + relative.size() >= PATH_MAX - 64) {
        Record(Failure::writeError, "its path is longer than macOS allows");
        return E_ABORT;
    }

    if (isDirectory) {
        const std::string folderPath = PlaceFolder(relative);
        if (folderPath.empty()) return E_ABORT;
        PendingFolder folder;
        folder.path = folderPath;
        folder.hasTime = hasTime;
        folder.seconds = seconds;
        folder.nanoseconds = nanoseconds;
        folder.hasMode = hasMode;
        folder.mode = mode;
        folders.push_back(folder);
        return S_OK;
    }

    const size_t lastSlash = relative.find_last_of('/');
    const std::string parent = PlaceFolder(lastSlash == std::string::npos ? "" : relative.substr(0, lastSlash));
    if (parent.empty()) return E_ABORT;
    const std::string path = parent + "/" + (lastSlash == std::string::npos ? relative : relative.substr(lastSlash + 1));

    UString hardLinkTarget;
    if (GetStringProperty(handle, index, kpidHardLink, hardLinkTarget) && !hardLinkTarget.IsEmpty()) {
        hardLinks.push_back({itemPath, path, Narrow(hardLinkTarget)});
        return S_OK;
    }

    // Skipping is decided now, before anything is decoded. Every other rule is
    // applied when the file is whole.
    if (overwrite == SZOverwriteSkip && PathExists(path)) return S_OK;
    finalPath = path;

    if (itemIsLink) {
        linkSpec = new MemoryOutStream;
        linkStream = linkSpec;
        *outStream = linkStream;
        linkStream->AddRef();
        return S_OK;
    }

    temporaryPath = HiddenSibling(path, ".part");
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
    journal.push_back({Step::created, path, ""});
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
        journal.push_back({Step::created, path, ""});
        summary.filesProcessed++;
    }
    hardLinks.clear();
}

void ExtractCallback::Finish() {
    AbandonInFlight();
    if (testOnly) return;
    if (progress.Cancelled()) {
        // Cancelling means "as if I had not started".
        Rollback();
        return;
    }
    if (failure == Failure::none) CreateHardLinks();
    DiscardBackups();

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
        // Unless the password has already been shown to be right, by the format's own
        // check or by an earlier item decoding with it, in which case it is damage.
        const bool garbage = result == kDataError || result == kCRCError;
        if (result == kWrongPassword
            || (itemEncrypted && garbage && !passwordProven && !itemVerifiesPassword)) {
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

    if (result == kOK && itemEncrypted) passwordProven = true;

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
