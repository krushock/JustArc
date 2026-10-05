// Extract.cpp
//
// Extracting and testing. 7-Zip decides the order items are decoded in and asks this
// callback for somewhere to put each one.

#include "BridgeInternal.h"

#include "7zip/Common/FileStreams.h"

#include <copyfile.h>
#include <fcntl.h>
#include <limits.h>
#include <strings.h>
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
    /// A link target is a path; anything past a few kilobytes is not one. The rest
    /// is swallowed rather than refused, so one absurd entry does not end the run.
    bool tooLong = false;
};

Z7_COM7F_IMF(MemoryOutStream::Write(const void *bytes, UInt32 size, UInt32 *processed)) {
    if (data.size() + size > 64 * 1024) {
        tooLong = true;
    } else {
        data.append(static_cast<const char *>(bytes), size);
    }
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

/// A symbolic or hard link, made once every file is in place.
struct PendingLink {
    std::string itemPath;
    /// Where the archive puts it, relative to the destination.
    std::string relative;
    std::string finalPath;
    std::string target;
};

/// One thing done to the destination, kept so it can be undone.
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
    /// For `movedAside`, the path the move made room at, as this run spells it. It
    /// can differ from `first` in case, or by a link higher up.
    std::string at;
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
/// there is touched, so a damaged archive leaves the files it could not produce as
/// they were, whichever overwrite rule is in force. Links are made the same way.
///
/// Everything that is done is also written down. A cancel, or a password that is
/// missing or wrong, undoes it all in reverse, so the destination is as it was found
/// and a second attempt starts clean: new files and folders are removed, files moved
/// aside are moved back, and replaced files are restored from the copy kept until
/// the end.
///
/// Symbolic links are made last, after every file, and then each is followed to
/// where it really leads. One that ends up outside the destination is removed,
/// however many other links it took to get there.
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
    bool keepLinksAsStored = false;
    UString password;
    bool hasPassword = false;

    Progress progress;
    SZExtractSummary summary {};

    bool passwordRequested = false;
    Failure failure = Failure::none;
    std::string failurePath;
    std::string failureDetail;
    /// True when an item was abandoned half-written with no cause recorded.
    bool abandonedAnItem = false;

    /// Tidies up after 7-Zip returns, however it returned.
    void Finish();

    /// The items hard links point at that were not themselves extracted, as happens
    /// when only the link was asked for. They are decoded in a second pass, into
    /// hidden files, so that the link can still be given its contents.
    std::vector<UInt32> TargetsToFetch();
    bool fetching = false;

private:
    // The item in flight.
    std::string itemPath;
    std::string itemRelative;
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
    std::vector<PendingLink> hardLinks;
    std::vector<PendingLink> symbolicLinks;
    std::vector<std::string> createdLinks;
    std::vector<Step> journal;
    /// Where each file of this run ended up, by the path the archive gave it. A hard
    /// link is a second name for one of these, not for whatever else has that name.
    std::map<std::string, std::string> placed;
    /// Folders that could not be made where the archive wanted them, because a file
    /// of that name is there, and where they went instead. Keyed by the path wanted.
    std::map<std::string, std::string> redirected;

    /// Hidden files holding the contents of hard-link targets fetched in the second pass.
    std::map<std::string, std::string> fetched;
    /// Folders that were already there, with the dates they had, so that an undone
    /// run does not leave them looking modified.
    std::map<std::string, std::pair<timespec, timespec>> visited;
    void Remember(const std::string &folder);

    /// True once an encrypted item has decoded, which proves the password.
    bool passwordProven = false;
    /// True when the format checks the password itself before decoding, so that a
    /// data error on this item means damage and not a wrong password.
    bool itemVerifiesPassword = false;
    /// Encrypted items that came out as garbage while the password was still unproven.
    /// Either the password is wrong or they are damaged; a later item settles which.
    unsigned suspects = 0;
    std::string firstSuspect;
    /// Set when going on is pointless: the password is known to be wrong, or the
    /// volume itself is refusing writes.
    bool hopeless = false;

    void Record(Failure kind, const std::string &detail) {
        // A wrong password explains a data error seen earlier, not the other way round.
        const bool upgrade = kind == Failure::wrongPassword && failure == Failure::dataError;
        if (failure != Failure::none && !upgrade) return;
        failure = kind;
        failurePath = itemPath;
        failureDetail = detail;
    }

    /// Records a failure to write, and whether it is the volume's or just this item's.
    /// A name the disk cannot hold says nothing about the next file; a full disk does.
    void RecordWrite(const char *what, int code) {
        Record(Failure::writeError, std::string(what) + ": " + std::strerror(code));
        if (code == ENOSPC || code == EDQUOT || code == EROFS || code == EIO) hopeless = true;
    }

    void AbandonInFlight();
    std::string PlaceFolder(const std::string &relative);
    std::string HiddenSibling(const std::string &path, const char *suffix);
    std::string TrueName(const std::string &path);
    bool Commit(const std::string &temporary, std::string &target);
    void UndoStepsAt(const std::string &path);
    void Rollback();
    void DiscardBackups();
    void CreateHardLinks();
    void CreateSymbolicLinks();
    bool Follows(std::vector<std::string> &stack, const std::string &target, int depth, int &budget);
    bool LinkLeadsInside(const std::string &linkPath);
    void SettlePasswordDoubt();
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

/// The path as the disk spells it. On a volume that ignores case, "A.txt" finds the
/// user's "a.txt", and that is the name to give back if it has to be restored.
std::string ExtractCallback::TrueName(const std::string &path) {
    const int descriptor = open(path.c_str(), O_EVTONLY | O_SYMLINK);
    if (descriptor < 0) return path;
    char buffer[PATH_MAX];
    const bool found = fcntl(descriptor, F_GETPATH, buffer) == 0;
    close(descriptor);
    return found ? std::string(buffer) : path;
}

/// Makes sure the folder at `relative`, a path under the destination, exists, and
/// returns where it really is. Empty when it could not be made.
///
/// Where a file already has the name a folder needs, the folder is made beside it
/// under a free name and everything addressed to it follows. An archive can hold both
/// "name" and "name/child"; a disk cannot, and losing either would be worse than
/// renaming one.
void ExtractCallback::Remember(const std::string &folder) {
    if (visited.count(folder)) return;
    struct stat info;
    if (stat(folder.c_str(), &info) != 0) return;
    visited[folder] = std::make_pair(info.st_atimespec, info.st_mtimespec);
}

std::string ExtractCallback::PlaceFolder(const std::string &relative) {
    std::string wanted = destination;
    std::string actual = destination;
    Remember(destination);
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
                Remember(actual);
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
            RecordWrite("could not create a folder", errno);
            return "";
        }
        journal.push_back({Step::createdFolder, candidate, "", ""});
        actual = candidate;
    }
    return actual;
}

/// Moves something complete from its temporary name to where it belongs, applying
/// the overwrite rule to whatever is already there. On return `target` is where it
/// went. False when it was not placed, in which case nothing that existed has been
/// changed and the temporary item is gone.
bool ExtractCallback::Commit(const std::string &temporary, std::string &target) {
    const bool exists = PathExists(target);
    // A folder in the way is never removed or moved: that could take a great deal of
    // the user's data with it. The new item goes beside it instead.
    const bool isFolder = exists && IsDirectoryPath(target) && !IsSymlinkPath(target);

    if (exists && !isFolder && overwrite == SZOverwriteReplace) {
        // rename() replaces a file in one step, so there is no moment at which neither
        // the old item nor the new one exists. A second name for the old one is made
        // first, so that it can be brought back; where the volume cannot do that,
        // the replacement simply cannot be undone.
        const std::string backup = HiddenSibling(target, ".bak");
        const bool keptCopy = linkat(AT_FDCWD, target.c_str(), AT_FDCWD, backup.c_str(), 0) == 0;
        if (rename(temporary.c_str(), target.c_str()) != 0) {
            const int code = errno;
            if (keptCopy) unlink(backup.c_str());
            unlink(temporary.c_str());
            RecordWrite("could not move the file into place", code);
            return false;
        }
        if (keptCopy) journal.push_back({Step::replaced, target, backup, ""});
        return true;
    }

    std::string original, aside;
    if (exists) {
        if (overwrite == SZOverwriteSkip) {
            unlink(temporary.c_str());
            return false;
        }
        if (isFolder || overwrite != SZOverwriteRenameExisting) {
            target = UniquePath(target);
        } else {
            original = TrueName(target);
            aside = UniquePath(target);
            if (rename(target.c_str(), aside.c_str()) != 0) {
                const int code = errno;
                unlink(temporary.c_str());
                RecordWrite("could not rename the existing item", code);
                return false;
            }
        }
    }

    if (rename(temporary.c_str(), target.c_str()) != 0) {
        const int code = errno;
        // Put back what was moved aside: nothing arrived to take its place.
        if (!aside.empty()) rename(aside.c_str(), original.c_str());
        unlink(temporary.c_str());
        RecordWrite("could not move the file into place", code);
        return false;
    }
    if (!aside.empty()) journal.push_back({Step::movedAside, original, aside, target});
    journal.push_back({Step::created, target, "", ""});
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
    // Folders that were already there keep the permissions they had, and the dates:
    // putting files in and taking them out again is not a change worth recording.
    folders.clear();
    createdLinks.clear();
    for (const auto &entry : visited) {
        const timespec times[2] = { entry.second.first, entry.second.second };
        utimensat(AT_FDCWD, entry.first.c_str(), times, 0);
    }
    for (const auto &entry : fetched) unlink(entry.second.c_str());
    fetched.clear();
}

/// Undoes what was done at one path, for a link that turned out to lead outside:
/// the link goes, and whatever was moved aside or replaced to make room comes back.
void ExtractCallback::UndoStepsAt(const std::string &path) {
    for (size_t index = journal.size(); index-- > 0;) {
        const Step step = journal[index];
        if (step.kind == Step::created && step.first == path) {
            unlink(path.c_str());
        } else if (step.kind == Step::replaced && step.first == path) {
            rename(step.second.c_str(), step.first.c_str());
        } else if (step.kind == Step::movedAside && step.at == path) {
            unlink(path.c_str());
            rename(step.second.c_str(), step.first.c_str());
        } else {
            continue;
        }
        journal.erase(journal.begin() + (long)index);
    }
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
    itemRelative.clear();

    IInArchive *handle = archive->archive;
    itemPath = Narrow(ItemPath(archive, index));
    itemEncrypted = GetBoolProperty(handle, index, kpidEncrypted);
    progress.SetCurrent(itemPath);
    extracting = askMode == NArchive::NExtract::NAskMode::kExtract;

    // Zip checks the password before it decodes anything: the AES verifier, or the
    // check byte of the old cipher. With one accepted, a failure further on is
    // damage. Other formats only find out by decoding.
    itemVerifiesPassword = itemEncrypted && EqualsIgnoringCase(archive->handler->name, UString(L"zip"));
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
        return S_OK;
    }

    // An item that cannot be placed is passed over, and the rest still extracted,
    // unless the cause is one that will stop every other item too.
    const HRESULT passOver = S_OK;

    if (fetching) {
        // Second pass: this item is wanted only for its contents, which go to a
        // hidden file and from there to the hard links that name it.
        if (isDirectory || itemIsLink) return S_OK;
        temporaryPath = HiddenSibling(destination + "/fetched", ".part");
        fileSpec = new COutFileStream;
        fileStream = fileSpec;
        if (!fileSpec->Create_NEW(temporaryPath.c_str())) {
            RecordWrite("could not create the file", errno);
            fileStream.Release();
            fileSpec = nullptr;
            temporaryPath.clear();
            return hopeless ? E_ABORT : passOver;
        }
        itemRelative = relative;
        *outStream = fileStream;
        fileStream->AddRef();
        return S_OK;
    }

    if (isDirectory) {
        const std::string folderPath = PlaceFolder(relative);
        if (folderPath.empty()) return (failure == Failure::unsafePath || hopeless) ? E_ABORT : passOver;
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
    if (parent.empty()) return (failure == Failure::unsafePath || hopeless) ? E_ABORT : passOver;
    const std::string path = parent + "/" + (lastSlash == std::string::npos ? relative : relative.substr(lastSlash + 1));

    // Skipping is decided now, before anything is decoded. Every other rule is
    // applied when the item is whole.
    if (overwrite == SZOverwriteSkip && PathExists(path)) return S_OK;

    UString hardLinkTarget;
    if (GetStringProperty(handle, index, kpidHardLink, hardLinkTarget) && !hardLinkTarget.IsEmpty()) {
        hardLinks.push_back({itemPath, relative, path, Narrow(hardLinkTarget)});
        return S_OK;
    }
    finalPath = path;
    itemRelative = relative;

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
        RecordWrite("could not create the file", errno);
        fileStream.Release();
        fileSpec = nullptr;
        temporaryPath.clear();
        finalPath.clear();
        return hopeless ? E_ABORT : passOver;
    }
    *outStream = fileStream;
    fileStream->AddRef();
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) {
    return S_OK;
}

/// Where a hard link's target sits in the archive, as a path under the destination.
static bool LinkTargetPath(const std::string &target, bool flatten, std::string &wanted) {
    if (!SanitizePath(target, wanted) || wanted.empty()) return false;
    if (flatten) {
        const size_t slash = wanted.find_last_of('/');
        if (slash != std::string::npos) wanted = wanted.substr(slash + 1);
    }
    return true;
}

std::vector<UInt32> ExtractCallback::TargetsToFetch() {
    std::vector<UInt32> indices;
    const bool undone = progress.Cancelled() || hopeless || failure == Failure::wrongPassword
        || (passwordRequested && !hasPassword);
    if (testOnly || undone || hardLinks.empty()) return indices;

    std::map<std::string, bool> needed;
    for (const PendingLink &pending : hardLinks) {
        std::string wanted;
        if (!LinkTargetPath(pending.target, flatten, wanted)) continue;
        if (wanted != pending.relative && !placed.count(wanted)) needed[wanted] = true;
    }
    if (needed.empty()) return indices;

    UInt32 count = 0;
    if (archive->archive->GetNumberOfItems(&count) != S_OK) return indices;
    for (UInt32 index = 0; index < count && !needed.empty(); index++) {
        if (ItemIsDirectory(archive->archive, index)) continue;
        UString link;
        // A link to a link has no contents of its own either.
        if (GetStringProperty(archive->archive, index, kpidHardLink, link) && !link.IsEmpty()) continue;
        std::string relative;
        if (!LinkTargetPath(Narrow(ItemPath(archive, index)), flatten, relative)) continue;
        const auto found = needed.find(relative);
        if (found == needed.end()) continue;
        indices.push_back(index);
        needed.erase(found);
    }
    return indices;
}

/// Hard links are second names for files of this archive: ones extracted in this
/// run, or fetched for the purpose. Never for whatever else has that name at the
/// destination, which is the user's and not what the link meant.
void ExtractCallback::CreateHardLinks() {
    for (const PendingLink &pending : hardLinks) {
        itemPath = pending.itemPath;
        std::string wanted;
        if (!LinkTargetPath(pending.target, flatten, wanted)) {
            summary.linksRefused++;
            continue;
        }
        if (wanted == pending.relative) continue;  // a link to itself names nothing new

        std::string source;
        const auto extracted = placed.find(wanted);
        const auto hidden = fetched.find(wanted);
        if (extracted != placed.end()) source = extracted->second;
        else if (hidden != fetched.end()) source = hidden->second;
        else {
            // The archive does not hold what it points at.
            summary.linksRefused++;
            continue;
        }

        const std::string temporary = HiddenSibling(pending.finalPath, ".part");
        if (link(source.c_str(), temporary.c_str()) != 0
            && copyfile(source.c_str(), temporary.c_str(), nullptr, COPYFILE_ALL) != 0) {
            RecordWrite("could not create a hard link", errno);
            continue;
        }
        std::string target = pending.finalPath;
        if (!Commit(temporary, target)) continue;
        placed[pending.relative] = target;
        summary.filesProcessed++;
    }
    hardLinks.clear();
    for (const auto &entry : fetched) unlink(entry.second.c_str());
    fetched.clear();
}

/// Follows `target` from the folder `stack` names, both relative to the destination,
/// the way the system would, through any links on the way. False if it ever leaves
/// the destination. What does not exist yet is taken at its word.
bool ExtractCallback::Follows(std::vector<std::string> &stack, const std::string &target, int depth, int &budget) {
    if (depth > 40 || target.empty() || target[0] == '/') return false;
    size_t start = 0;
    while (start <= target.size()) {
        const size_t slash = target.find('/', start);
        const std::string part = target.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        start = slash == std::string::npos ? target.size() + 1 : slash + 1;
        if (part.empty() || part == ".") continue;
        if (--budget < 0) return false;
        if (part == "..") {
            if (stack.empty()) return false;
            stack.pop_back();
            continue;
        }
        stack.push_back(part);
        std::string path = destination;
        for (const std::string &component : stack) path += "/" + component;
        struct stat info;
        if (lstat(path.c_str(), &info) == 0 && S_ISLNK(info.st_mode)) {
            char buffer[PATH_MAX];
            const ssize_t length = readlink(path.c_str(), buffer, sizeof(buffer));
            if (length <= 0) return false;
            // The link stands for what it points to, from the folder it is in.
            stack.pop_back();
            if (!Follows(stack, std::string(buffer, (size_t)length), depth + 1, budget)) return false;
        }
    }
    return true;
}

bool ExtractCallback::LinkLeadsInside(const std::string &linkPath) {
    char buffer[PATH_MAX];
    const ssize_t length = readlink(linkPath.c_str(), buffer, sizeof(buffer));
    if (length <= 0) return false;

    std::vector<std::string> stack;
    const std::string folder = linkPath.substr(0, linkPath.find_last_of('/'));
    if (folder.size() > destination.size()) {
        const std::string relative = folder.substr(destination.size() + 1);
        size_t start = 0;
        while (start <= relative.size()) {
            const size_t slash = relative.find('/', start);
            const std::string part = relative.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
            if (!part.empty()) stack.push_back(part);
            if (slash == std::string::npos) break;
            start = slash + 1;
        }
    }
    int budget = 4096;
    return Follows(stack, std::string(buffer, (size_t)length), 0, budget);
}

/// Makes the symbolic links, then removes any that lead outside the destination.
///
/// A link cannot be judged when it is made: "a/../.." is harmless while "a" is a
/// folder, and an escape once a later entry has turned "a" into a link to ".". So
/// every link is made first, and each is then followed on the disk as it finally is.
/// 7-Zip refuses such links by default for the same reason: anything that later
/// follows one would be reading or writing somewhere the user never chose.
void ExtractCallback::CreateSymbolicLinks() {
    for (const PendingLink &pending : symbolicLinks) {
        itemPath = pending.itemPath;
        const std::string &target = pending.target;
        if (target.empty() || (target[0] == '/' && !keepLinksAsStored)
            || target.find('\0') != std::string::npos || target.size() >= PATH_MAX) {
            summary.linksRefused++;
            continue;
        }
        const std::string temporary = HiddenSibling(pending.finalPath, ".part");
        if (symlink(target.c_str(), temporary.c_str()) != 0) {
            RecordWrite("could not create a link", errno);
            continue;
        }
        std::string placedAt = pending.finalPath;
        if (!Commit(temporary, placedAt)) continue;
        createdLinks.push_back(placedAt);
        summary.filesProcessed++;
    }
    symbolicLinks.clear();

    for (const std::string &link : createdLinks) {
        if (keepLinksAsStored || LinkLeadsInside(link)) continue;
        // Taken away again, and whatever it displaced is put back.
        UndoStepsAt(link);
        if (IsSymlinkPath(link)) unlink(link.c_str());
        summary.linksRefused++;
        if (summary.filesProcessed > 0) summary.filesProcessed--;
    }
    createdLinks.clear();
}

/// Decides what the encrypted items that came out as garbage were.
void ExtractCallback::SettlePasswordDoubt() {
    if (suspects == 0 || failure == Failure::wrongPassword) return;
    const std::string current = itemPath;
    itemPath = firstSuspect;
    if (passwordProven) {
        // Another encrypted item decoded with this password, so these are damaged.
        Record(Failure::dataError, "the data is damaged");
    } else {
        Record(Failure::wrongPassword, "");
    }
    itemPath = current;
}

void ExtractCallback::Finish() {
    AbandonInFlight();
    if (testOnly) {
        SettlePasswordDoubt();
        return;
    }
    SettlePasswordDoubt();

    // A cancel means "as if I had not started". So does a password that is missing
    // or wrong: the caller asks for it and tries again, and a second run over the
    // leavings of the first would skip or duplicate what was already extracted.
    const bool passwordFailed = failure == Failure::wrongPassword || (passwordRequested && !hasPassword);
    if (progress.Cancelled() || passwordFailed) {
        Rollback();
        return;
    }

    if (!hopeless) {
        CreateHardLinks();
        CreateSymbolicLinks();
    }
    for (const auto &entry : fetched) unlink(entry.second.c_str());
    fetched.clear();
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
        const bool garbage = result == kDataError || result == kCRCError;
        if (result == kWrongPassword) {
            Record(Failure::wrongPassword, "");
            hopeless = true;
        } else if (itemEncrypted && garbage && !itemVerifiesPassword && !passwordProven) {
            // With the wrong key, a format that does not check the password reports
            // garbage, exactly as it does for damage. Which this is cannot be known
            // yet: if a later item decodes, the password was right and this one is
            // damaged. A few in a row with nothing decoded is a wrong password.
            if (suspects++ == 0) firstSuspect = itemPath;
            if (suspects >= 3) {
                Record(Failure::wrongPassword, "");
                hopeless = true;
            }
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
        if (closed != S_OK) RecordWrite("could not finish writing the file", errno ? errno : EIO);

        if (result != kOK || closed != S_OK) {
            // A half-written or wrongly decrypted file is worse than no file, and
            // whatever was there before has not been touched.
            unlink(temporaryPath.c_str());
        } else if (fetching) {
            mode_t permissions = 0;
            if (hasMode && UsablePermissions(mode, permissions)) chmod(temporaryPath.c_str(), permissions);
            fetched[itemRelative] = temporaryPath;
        } else {
            std::string target = finalPath;
            if (Commit(temporaryPath, target)) {
                mode_t permissions = 0;
                if (hasMode && UsablePermissions(mode, permissions)) chmod(target.c_str(), permissions);
                placed[itemRelative] = target;
                summary.filesProcessed++;
            }
        }
        temporaryPath.clear();
    } else if (linkStream) {
        const std::string target = linkTargetFromHeader.empty() ? linkSpec->data : linkTargetFromHeader;
        const bool tooLong = linkSpec->tooLong;
        linkStream.Release();
        linkSpec = nullptr;
        if (result == kOK) {
            if (tooLong) {
                summary.linksRefused++;
            } else {
                symbolicLinks.push_back({itemPath, itemRelative, finalPath, target});
            }
        }
    } else if (result == kOK && !extracting) {
        summary.filesProcessed++;  // testing
    }

    if (hopeless) return E_ABORT;
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
    callbackSpec->keepLinksAsStored = options->keepLinksAsStored;
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

    // Hard links whose files were not part of this extraction get those files'
    // contents from a second pass over just those items.
    if (result == S_OK && !options->testOnly) {
        std::vector<UInt32> targets = callbackSpec->TargetsToFetch();
        if (!targets.empty()) {
            std::sort(targets.begin(), targets.end());
            callbackSpec->fetching = true;
            archive->archive->Extract(targets.data(), (UInt32)targets.size(), 0, callback);
            callbackSpec->fetching = false;
        }
    }

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
            // 7-Zip stopped partway through a file and named no cause of its own. A
            // disk that filled up is the usual one, though not the only one.
            Fail(error, SZStatusWriteError, "The disk could not take the file being written. It may be full.");
            return SZStatusWriteError;
        }
        Fail(error, SZStatusFailed, DescribeHRESULT(result));
        return SZStatusFailed;
    }
    return SZStatusOK;
}
