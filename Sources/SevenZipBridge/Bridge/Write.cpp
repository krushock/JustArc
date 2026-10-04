// Write.cpp
//
// Creating archives and changing existing ones. 7-Zip never edits an archive where it
// lies: it writes a complete new one, copying the items it keeps straight from the
// old file without recompressing them. The caller then swaps the new file in.

#include "BridgeInternal.h"

#include "Windows/FileFind.h"
#include "Windows/TimeUtils.h"
#include "7zip/Common/FileStreams.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <set>
#include <map>

using namespace NWindows;
using namespace SZBridge;

namespace {

/// Hands a symbolic link's target to formats that store it as data.
class MemoryInStream Z7_final:
    public ISequentialInStream,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_1(ISequentialInStream)
public:
    std::string data;
    size_t position = 0;
};

Z7_COM7F_IMF(MemoryInStream::Read(void *bytes, UInt32 size, UInt32 *processed)) {
    const size_t remaining = data.size() - position;
    const size_t count = remaining < size ? remaining : size;
    std::memcpy(bytes, data.data() + position, count);
    position += count;
    if (processed) *processed = (UInt32)count;
    return S_OK;
}

struct Entry {
    bool existing = false;
    UInt32 sourceIndex = 0;
    bool renamed = false;
    UString path;

    std::string diskPath;
    NFile::NFind::CFileInfo info;
    bool isLink = false;
    std::string linkTarget;
};

class UpdateCallback Z7_final:
    public IArchiveUpdateCallback2,
    public ICryptoGetTextPassword2,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_3(IArchiveUpdateCallback2, ICryptoGetTextPassword2, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IArchiveUpdateCallback)

public:
    SZArchive *source = nullptr;
    std::vector<Entry> *entries = nullptr;
    /// Tar keeps a link's target in its header; zip and 7z keep it as the item's data.
    bool linkTargetInHeader = false;
    UString password;
    bool hasPassword = false;
    /// For reading the source: 7-Zip has to decode an encrypted solid block to take
    /// one file out of it, and asks for the password it was written with.
    UString sourcePassword;
    bool hasSourcePassword = false;
    bool sourcePasswordRequested = false;
    Progress progress;

    std::string failurePath;
    std::string failureDetail;
};

Z7_COM7F_IMF(UpdateCallback::SetTotal(UInt64 size)) {
    progress.SetTotal(size);
    return progress.Report() ? S_OK : E_ABORT;
}

Z7_COM7F_IMF(UpdateCallback::SetCompleted(const UInt64 *value)) {
    if (value) progress.SetCompleted(*value);
    return progress.Report() ? S_OK : E_ABORT;
}

Z7_COM7F_IMF(UpdateCallback::GetUpdateItemInfo(UInt32 index, Int32 *newData, Int32 *newProperties,
                                               UInt32 *indexInArchive)) {
    const Entry &entry = (*entries)[index];
    if (newData) *newData = entry.existing ? 0 : 1;
    if (newProperties) *newProperties = (entry.existing && !entry.renamed) ? 0 : 1;
    if (indexInArchive) *indexInArchive = entry.existing ? entry.sourceIndex : (UInt32)(Int32)-1;
    return S_OK;
}

Z7_COM7F_IMF(UpdateCallback::GetProperty(UInt32 index, PROPID propID, PROPVARIANT *value)) {
    const Entry &entry = (*entries)[index];
    NCOM::CPropVariant prop;

    if (propID == kpidIsAnti) {
        prop = false;
        prop.Detach(value);
        return S_OK;
    }

    if (entry.existing) {
        // A renamed item keeps everything but its name, so the rest comes from the source.
        if (propID == kpidPath) {
            prop = entry.path;
            prop.Detach(value);
            return S_OK;
        }
        return source->archive->GetProperty(entry.sourceIndex, propID, value);
    }

    const NFile::NFind::CFileInfo &info = entry.info;
    switch (propID) {
        case kpidPath:
            prop = entry.path;
            break;
        case kpidIsDir:
            prop = info.IsDir();
            break;
        case kpidSize:
            if (entry.isLink) prop = (UInt64)(linkTargetInHeader ? 0 : entry.linkTarget.size());
            else prop = info.IsDir() ? (UInt64)0 : info.Size;
            break;
        case kpidMTime:
            PropVariant_SetFrom_FiTime(prop, info.MTime);
            break;
        case kpidCTime:
            PropVariant_SetFrom_FiTime(prop, info.CTime);
            break;
        case kpidATime:
            PropVariant_SetFrom_FiTime(prop, info.ATime);
            break;
        case kpidAttrib:
            prop = (UInt32)info.GetWinAttrib();
            break;
        case kpidPosixAttrib:
            prop = (UInt32)info.GetPosixAttrib();
            break;
        case kpidSymLink:
            if (entry.isLink) prop = Wide(entry.linkTarget.c_str());
            break;
        default:
            break;
    }
    prop.Detach(value);
    return S_OK;
}

Z7_COM7F_IMF(UpdateCallback::GetStream(UInt32 index, ISequentialInStream **inStream)) {
    *inStream = nullptr;
    const Entry &entry = (*entries)[index];
    if (entry.existing) return S_OK;
    progress.SetCurrent(Narrow(entry.path));
    if (!progress.Report()) return E_ABORT;
    if (entry.info.IsDir()) return S_OK;

    if (entry.isLink) {
        auto *spec = new MemoryInStream;
        CMyComPtr<ISequentialInStream> stream = spec;
        if (!linkTargetInHeader) spec->data = entry.linkTarget;
        *inStream = stream.Detach();
        return S_OK;
    }

    auto *spec = new CInFileStream;
    CMyComPtr<ISequentialInStream> stream = spec;
    if (!spec->Open(entry.diskPath.c_str())) {
        failurePath = entry.diskPath;
        failureDetail = std::strerror(errno);
        return E_ABORT;
    }
    *inStream = stream.Detach();
    return S_OK;
}

Z7_COM7F_IMF(UpdateCallback::SetOperationResult(Int32)) {
    return S_OK;
}

Z7_COM7F_IMF(UpdateCallback::GetVolumeSize(UInt32, UInt64 *)) {
    // Volumes are split after writing, which works the same for every format.
    return S_FALSE;
}

Z7_COM7F_IMF(UpdateCallback::GetVolumeStream(UInt32, ISequentialOutStream **)) {
    return E_NOTIMPL;
}

Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *result)) {
    *passwordIsDefined = hasPassword ? 1 : 0;
    return StringToBstr(hasPassword ? password : UString(), result);
}

Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword(BSTR *result)) {
    sourcePasswordRequested = true;
    if (!hasSourcePassword) return E_ABORT;
    return StringToBstr(sourcePassword, result);
}

bool SourceIsEncrypted(SZArchive *source) {
    if (!source) return false;
    UInt32 count = 0;
    if (source->archive->GetNumberOfItems(&count) != S_OK) return false;
    for (UInt32 index = 0; index < count; index++) {
        if (GetBoolProperty(source->archive, index, kpidEncrypted)) return true;
    }
    return false;
}

bool Named(const Handler *handler, const wchar_t *name) {
    return EqualsIgnoringCase(handler->name, UString(name));
}

}  // namespace

extern "C" SZStatus sz_write(SZArchive *source,
                             const uint32_t *removed, uint32_t removedCount,
                             const SZRename *renames, uint32_t renameCount,
                             const SZNewItem *added, uint32_t addedCount,
                             const char *outputPath, const SZWriteOptions *options,
                             SZProgressCallback progress, void *context,
                             SZError *error) {
    Library *library = LoadedLibrary();
    if (!library) {
        Fail(error, SZStatusLibraryMissing, "The 7-Zip library is not loaded.");
        return SZStatusLibraryMissing;
    }
    if (!outputPath || !options) {
        Fail(error, SZStatusFailed, "Nowhere to write the archive.");
        return SZStatusFailed;
    }

    // Choose the writer: the source's own handler when carrying items over, since
    // only it can copy them without recompressing.
    const Handler *handler = nullptr;
    CMyComPtr<IOutArchive> outArchive;
    if (source) {
        handler = source->handler;
        source->archive.QueryInterface(IID_IOutArchive, (void **)&outArchive);
        if (!outArchive || !handler->canWrite) {
            Fail(error, SZStatusUnsupported, source->formatName + " archives cannot be changed.");
            return SZStatusUnsupported;
        }
    } else {
        handler = FindHandler(Wide(options->formatName));
        if (!handler || !handler->canWrite) {
            Fail(error, SZStatusUnsupported,
                 std::string("7-Zip cannot write ") + (options->formatName ? options->formatName : "this format") + " archives.");
            return SZStatusUnsupported;
        }
        if (library->createObject(&handler->classID, &IID_IOutArchive, (void **)&outArchive) != S_OK || !outArchive) {
            Fail(error, SZStatusUnsupported, "7-Zip could not create a writer for this format.");
            return SZStatusUnsupported;
        }
    }

    // Build the item list: kept items first, in their original order, then additions.
    std::vector<Entry> entries;
    if (source) {
        const std::set<uint32_t> dropped(removed, removed + removedCount);
        std::map<uint32_t, UString> renamed;
        for (uint32_t i = 0; i < renameCount; i++) renamed[renames[i].index] = Wide(renames[i].newPath);

        const uint32_t count = sz_item_count(source);
        for (uint32_t index = 0; index < count; index++) {
            if (dropped.count(index)) continue;
            Entry entry;
            entry.existing = true;
            entry.sourceIndex = index;
            auto rename = renamed.find(index);
            if (rename != renamed.end()) {
                entry.renamed = true;
                entry.path = rename->second;
            }
            entries.push_back(entry);
        }
    }

    for (uint32_t i = 0; i < addedCount; i++) {
        Entry entry;
        entry.path = Wide(added[i].archivePath);
        entry.diskPath = added[i].diskPath ? added[i].diskPath : "";
        // Looked up without following links, so a link is stored as a link.
        if (!entry.info.Find(entry.diskPath.c_str(), false)) {
            Fail(error, SZStatusCannotOpenFile, "Cannot read " + entry.diskPath + ": " + std::strerror(errno));
            return SZStatusCannotOpenFile;
        }
        entry.isLink = entry.info.IsPosixLink();
        if (entry.isLink) {
            char target[4096];
            const ssize_t length = readlink(entry.diskPath.c_str(), target, sizeof(target) - 1);
            if (length < 0) {
                Fail(error, SZStatusCannotOpenFile, "Cannot read the link " + entry.diskPath);
                return SZStatusCannotOpenFile;
            }
            entry.linkTarget.assign(target, (size_t)length);
        }
        entries.push_back(entry);
    }

    // Format settings. Only what a format understands is sent, since a handler
    // rejects the whole set when it meets a name it does not know.
    const wchar_t *names[4];
    NCOM::CPropVariant values[4];
    unsigned settingCount = 0;
    const bool takesLevel = Named(handler, L"7z") || Named(handler, L"zip") || Named(handler, L"gzip")
        || Named(handler, L"bzip2") || Named(handler, L"xz") || Named(handler, L"zstd");
    const bool encrypting = options->password && options->password[0];
    if (options->level >= 0 && takesLevel) {
        names[settingCount] = L"x";
        values[settingCount++] = (UInt32)options->level;
    }
    if (Named(handler, L"7z") && options->solid >= 0) {
        names[settingCount] = L"s";
        values[settingCount++] = options->solid != 0;
    }
    if (Named(handler, L"7z") && encrypting && options->encryptHeaders) {
        names[settingCount] = L"he";
        values[settingCount++] = true;
    }
    if (Named(handler, L"zip") && encrypting) {
        names[settingCount] = L"em";
        values[settingCount++] = options->zipEncryption && options->zipEncryption[0]
            ? Wide(options->zipEncryption) : UString(L"AES256");
    }
    if (settingCount) {
        CMyComPtr<ISetProperties> setProperties;
        outArchive.QueryInterface(IID_ISetProperties, (void **)&setProperties);
        if (!setProperties) {
            Fail(error, SZStatusUnsupported, "This format takes no settings.");
            return SZStatusUnsupported;
        }
        const HRESULT set = setProperties->SetProperties(names, values, settingCount);
        if (set != S_OK) {
            Fail(error, SZStatusUnsupported, "The format rejected a setting: " + DescribeHRESULT(set));
            return SZStatusUnsupported;
        }
    }

    auto *callbackSpec = new UpdateCallback;
    CMyComPtr<IArchiveUpdateCallback2> callback = callbackSpec;
    callbackSpec->source = source;
    callbackSpec->entries = &entries;
    callbackSpec->linkTargetInHeader = Named(handler, L"tar");
    callbackSpec->progress.callback = progress;
    callbackSpec->progress.context = context;
    if (encrypting) {
        callbackSpec->password = Wide(options->password);
        callbackSpec->hasPassword = true;
    }
    // The password the source was opened with reads it; failing that, the one the
    // caller gave for writing, since an edited archive keeps its password.
    if (source && source->hasPassword) {
        callbackSpec->sourcePassword = source->password;
        callbackSpec->hasSourcePassword = true;
    } else if (encrypting) {
        callbackSpec->sourcePassword = callbackSpec->password;
        callbackSpec->hasSourcePassword = true;
    }

    auto *outSpec = new COutFileStream;
    CMyComPtr<IOutStream> outStream = outSpec;
    if (!outSpec->Create_ALWAYS(outputPath)) {
        Fail(error, SZStatusWriteError, std::string("Cannot create ") + outputPath + ": " + std::strerror(errno));
        return SZStatusWriteError;
    }

    const HRESULT result = outArchive->UpdateItems(outStream, (UInt32)entries.size(), callback);
    const HRESULT closed = outSpec->Close();
    outStream.Release();

    SZStatus status = SZStatusOK;
    if (callbackSpec->progress.Cancelled()) {
        Fail(error, SZStatusCancelled, "The operation was cancelled.");
        status = SZStatusCancelled;
    } else if (result != S_OK && (callbackSpec->sourcePasswordRequested
                                  || (callbackSpec->hasPassword && SourceIsEncrypted(source)))) {
        // Existing items had to be decoded to be carried over, and could not be.
        // When a password for writing is given, 7-Zip decodes with that one without
        // asking, so a failure on an encrypted source is read the same way.
        if (callbackSpec->hasSourcePassword) {
            Fail(error, SZStatusWrongPassword, "The password is incorrect.");
            status = SZStatusWrongPassword;
        } else {
            Fail(error, SZStatusPasswordRequired, "This archive is password protected.");
            status = SZStatusPasswordRequired;
        }
    } else if (!callbackSpec->failurePath.empty()) {
        Fail(error, SZStatusCannotOpenFile, "Cannot read " + callbackSpec->failurePath + ": " + callbackSpec->failureDetail);
        status = SZStatusCannotOpenFile;
    } else if (result != S_OK) {
        Fail(error, SZStatusFailed, "7-Zip could not write the archive: " + DescribeHRESULT(result));
        status = SZStatusFailed;
    } else if (closed != S_OK) {
        Fail(error, SZStatusWriteError, "The archive could not be finished on disk.");
        status = SZStatusWriteError;
    }

    if (status != SZStatusOK) unlink(outputPath);
    return status;
}
