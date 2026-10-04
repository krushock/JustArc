// Library.cpp
//
// Loading 7z.so, identifying formats, and reading archives.

// MyInitGuid.h must come before any header that declares an interface ID, so that
// this translation unit holds the one definition of each GUID the bridge uses.
#include "Common/Common.h"
#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"

#include "BridgeInternal.h"

#include "7zip/Common/FileStreams.h"
#include "../C/7zVersion.h"

#include <dlfcn.h>
#include <langinfo.h>
#include <locale.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>

using namespace NWindows;

namespace SZBridge {

// MARK: - Text

UString Wide(const char *utf8) {
    UString result;
    if (utf8) ConvertUTF8ToUnicode(AString(utf8), result);
    return result;
}

std::string Narrow(const UString &wide) {
    AString result;
    ConvertUnicodeToUTF8(wide, result);
    return std::string(result.Ptr(), result.Len());
}

std::string Narrow(const wchar_t *wide) {
    return Narrow(UString(wide ? wide : L""));
}

bool EqualsIgnoringCase(const UString &a, const UString &b) {
    return a.IsEqualTo_NoCase(b.Ptr());
}

// MARK: - Errors

void Fail(SZError *error, SZStatus status, const std::string &message) {
    if (!error) return;
    error->status = status;
    std::snprintf(error->message, sizeof(error->message), "%s", message.c_str());
}

std::string DescribeHRESULT(HRESULT result) {
    switch (result) {
        case S_OK: return "no error";
        case S_FALSE: return "the data is not in this format";
        case E_ABORT: return "the operation was stopped";
        case E_OUTOFMEMORY: return "there was not enough memory";
        case E_NOTIMPL: return "the format does not support this";
        case E_INVALIDARG: return "the format rejected a setting";
        default: break;
    }
    // An errno from a failed read or write, which 7-Zip wraps in a code of its own.
    if (((unsigned)result & 0xFFFF0000) == 0x88000000) {
        return std::strerror((int)((unsigned)result & 0xFFFF));
    }
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "7-Zip error 0x%08X", (unsigned)result);
    return buffer;
}

// MARK: - Library

static std::mutex g_loadLock;
static Library *g_library = nullptr;

Library *LoadedLibrary() {
    return g_library;
}

const Handler *FindHandler(const UString &name) {
    if (!g_library) return nullptr;
    for (const Handler &handler : g_library->handlers) {
        if (EqualsIgnoringCase(handler.name, name)) return &handler;
    }
    return nullptr;
}

static bool ReadHandlerString(Func_GetHandlerProperty2 get, UInt32 index, PROPID id, UString &out) {
    NCOM::CPropVariant prop;
    if (get(index, id, &prop) != S_OK || prop.vt != VT_BSTR || !prop.bstrVal) return false;
    out = prop.bstrVal;
    return true;
}

static bool ReadHandlerBinary(Func_GetHandlerProperty2 get, UInt32 index, PROPID id, std::vector<Byte> &out) {
    NCOM::CPropVariant prop;
    if (get(index, id, &prop) != S_OK || prop.vt != VT_BSTR || !prop.bstrVal) return false;
    const UINT length = ::SysStringByteLen(prop.bstrVal);
    const Byte *bytes = reinterpret_cast<const Byte *>(prop.bstrVal);
    out.assign(bytes, bytes + length);
    return true;
}

static bool ReadHandlerUInt32(Func_GetHandlerProperty2 get, UInt32 index, PROPID id, UInt32 &out) {
    NCOM::CPropVariant prop;
    if (get(index, id, &prop) != S_OK || prop.vt != VT_UI4) return false;
    out = prop.ulVal;
    return true;
}

static bool ReadHandlerBool(Func_GetHandlerProperty2 get, UInt32 index, PROPID id) {
    NCOM::CPropVariant prop;
    if (get(index, id, &prop) != S_OK || prop.vt != VT_BOOL) return false;
    return prop.boolVal != VARIANT_FALSE;
}

/// A multi-signature property is a run of [length byte][signature bytes] records.
static void SplitMultiSignature(const std::vector<Byte> &data, std::vector<std::vector<Byte>> &out) {
    size_t position = 0;
    while (position < data.size()) {
        const size_t length = data[position++];
        if (length == 0 || position + length > data.size()) break;
        out.emplace_back(data.begin() + (long)position, data.begin() + (long)(position + length));
        position += length;
    }
}

}  // namespace SZBridge

using namespace SZBridge;

extern "C" SZStatus sz_load(const char *libraryPath, SZError *error) {
    std::lock_guard<std::mutex> lock(g_loadLock);
    if (g_library) return SZStatusOK;

    // 7-Zip decides how to read names that do not say they are UTF-8 at the moment
    // it is loaded, from the process's locale: in a UTF-8 locale it reads them as
    // UTF-8, otherwise byte by byte. An app starts in the "C" locale, which made a
    // name such as "café" from the macOS zip tool come out as "cafÃ©".
    const char *codeset = nl_langinfo(CODESET);
    if (!codeset || strcasecmp(codeset, "UTF-8") != 0) setlocale(LC_CTYPE, "UTF-8");

    void *module = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
    if (!module) {
        const char *reason = dlerror();
        Fail(error, SZStatusLibraryMissing,
             std::string("The 7-Zip library could not be loaded: ") + (reason ? reason : "unknown reason"));
        return SZStatusLibraryMissing;
    }

    auto createObject = (Func_CreateObject)dlsym(module, "CreateObject");
    auto numberOfFormats = (Func_GetNumberOfFormats)dlsym(module, "GetNumberOfFormats");
    auto handlerProperty = (Func_GetHandlerProperty2)dlsym(module, "GetHandlerProperty2");
    auto getIsArc = (Func_GetIsArc)dlsym(module, "GetIsArc");
    if (!createObject || !numberOfFormats || !handlerProperty) {
        dlclose(module);
        Fail(error, SZStatusLibraryMissing, "The 7-Zip library is missing its entry points.");
        return SZStatusLibraryMissing;
    }

    auto *library = new Library();
    library->module = module;
    library->createObject = createObject;

    UInt32 count = 0;
    numberOfFormats(&count);
    for (UInt32 index = 0; index < count; index++) {
        Handler handler;
        if (!ReadHandlerString(handlerProperty, index, NArchive::NHandlerPropID::kName, handler.name)) continue;

        std::vector<Byte> classID;
        if (!ReadHandlerBinary(handlerProperty, index, NArchive::NHandlerPropID::kClassID, classID)
            || classID.size() != sizeof(GUID)) continue;
        std::memcpy(&handler.classID, classID.data(), sizeof(GUID));

        ReadHandlerString(handlerProperty, index, NArchive::NHandlerPropID::kExtension, handler.extensions);
        handler.extensions.MakeLower_Ascii();
        ReadHandlerString(handlerProperty, index, NArchive::NHandlerPropID::kAddExtension, handler.addExtensions);
        handler.canWrite = ReadHandlerBool(handlerProperty, index, NArchive::NHandlerPropID::kUpdate);

        UInt32 flags = 0;
        ReadHandlerUInt32(handlerProperty, index, NArchive::NHandlerPropID::kFlags, flags);
        // Formats that ask to be opened only by extension would otherwise claim
        // ordinary files by their content.
        const bool byExtensionOnly = (flags & NArcInfoFlags::kByExtOnlyOpen) != 0;

        if (!byExtensionOnly) {
            std::vector<Byte> signature;
            if (ReadHandlerBinary(handlerProperty, index, NArchive::NHandlerPropID::kSignature, signature)
                && !signature.empty()) {
                handler.signatures.push_back(signature);
            }
            std::vector<Byte> multi;
            if (ReadHandlerBinary(handlerProperty, index, NArchive::NHandlerPropID::kMultiSignature, multi)) {
                SplitMultiSignature(multi, handler.signatures);
            }
            ReadHandlerUInt32(handlerProperty, index, NArchive::NHandlerPropID::kSignatureOffset,
                              handler.signatureOffset);
            if (getIsArc) {
                Func_IsArc isArc = nullptr;
                if (getIsArc(index, &isArc) == S_OK) handler.isArc = isArc;
            }
        }
        library->handlers.push_back(handler);
    }

    g_library = library;
    return SZStatusOK;
}

extern "C" bool sz_is_loaded(void) {
    return g_library != nullptr;
}

extern "C" const char *sz_version(void) {
    return MY_VERSION_NUMBERS;
}

extern "C" uint32_t sz_format_count(void) {
    return g_library ? (uint32_t)g_library->handlers.size() : 0;
}

extern "C" const char *sz_format_name(uint32_t index) {
    static thread_local std::string name;
    if (!g_library || index >= g_library->handlers.size()) return "";
    name = Narrow(g_library->handlers[index].name);
    return name.c_str();
}

extern "C" bool sz_format_can_write(uint32_t index) {
    return g_library && index < g_library->handlers.size() && g_library->handlers[index].canWrite;
}

// MARK: - Opening

namespace {

class OpenCallback Z7_final:
    public IArchiveOpenCallback,
    public IArchiveOpenVolumeCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, IArchiveOpenVolumeCallback, ICryptoGetTextPassword)
public:
    UString password;
    bool hasPassword = false;
    bool passwordRequested = false;
    /// The folder holding the archive, with a trailing slash, and the file's own
    /// name: what a handler needs to find the archive's other volumes.
    std::string folder;
    UString name;
};

Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }

Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *result)) {
    passwordRequested = true;
    // Refusing here makes 7-Zip give up at once instead of trying to prompt.
    if (!hasPassword) return E_ABORT;
    return StringToBstr(password, result);
}

Z7_COM7F_IMF(OpenCallback::GetProperty(PROPID propID, PROPVARIANT *value)) {
    NCOM::CPropVariant prop;
    if (propID == kpidName) prop = name;
    prop.Detach(value);
    return S_OK;
}

Z7_COM7F_IMF(OpenCallback::GetStream(const wchar_t *volumeName, IInStream **inStream)) {
    *inStream = nullptr;
    const std::string leaf = Narrow(volumeName);
    // Volumes sit beside the first one; a name that reaches elsewhere is not one.
    if (leaf.empty() || leaf.find('/') != std::string::npos) return S_FALSE;
    const std::string path = folder + leaf;
    if (!PathExists(path) || IsDirectoryPath(path)) return S_FALSE;
    auto *streamSpec = new CInFileStream;
    CMyComPtr<IInStream> stream = streamSpec;
    if (!streamSpec->Open(path.c_str())) return S_FALSE;
    *inStream = stream.Detach();
    return S_OK;
}

std::vector<UString> Split(const UString &text) {
    std::vector<UString> parts;
    UString current;
    for (unsigned i = 0; i < text.Len(); i++) {
        const wchar_t c = text[i];
        if (c == L' ') {
            if (!current.IsEmpty()) parts.push_back(current);
            current.Empty();
        } else {
            current += c;
        }
    }
    if (!current.IsEmpty()) parts.push_back(current);
    return parts;
}

bool HasExtension(const Handler &handler, const UString &extension) {
    if (extension.IsEmpty()) return false;
    for (const UString &candidate : Split(handler.extensions)) {
        if (EqualsIgnoringCase(candidate, extension)) return true;
    }
    return false;
}

/// The order 7-Zip itself uses: a signature at a known offset is the strongest
/// evidence, a format's own content check next, and the extension last.
// ISO keeps its signature 32 KB in, so the head has to reach past that.
const size_t kHeadSize = 1 << 17;

std::vector<Byte> ReadHead(IInStream *stream, size_t limit) {
    std::vector<Byte> buffer(limit);
    size_t filled = 0;
    if (stream->Seek(0, STREAM_SEEK_SET, nullptr) != S_OK) return {};
    while (filled < limit) {
        UInt32 processed = 0;
        if (stream->Read(buffer.data() + filled, (UInt32)(limit - filled), &processed) != S_OK || processed == 0) break;
        filled += processed;
    }
    buffer.resize(filled);
    return buffer;
}

bool IsVolumeNumber(const UString &extension) {
    if (extension.IsEmpty()) return false;
    for (unsigned i = 0; i < extension.Len(); i++) {
        if (extension[i] < L'0' || extension[i] > L'9') return false;
    }
    return true;
}

std::vector<const Handler *> Candidates(const std::vector<Byte> &head, const UString &extensionHint) {
    std::vector<const Handler *> ordered;
    auto add = [&ordered](const Handler *handler) {
        if (std::find(ordered.begin(), ordered.end(), handler) == ordered.end()) ordered.push_back(handler);
    };

    // "name.7z.001" starts with a 7z signature but holds only part of the archive;
    // the volumes have to be joined first, which is what the Split handler does.
    if (IsVolumeNumber(extensionHint)) {
        if (const Handler *split = FindHandler(L"Split")) add(split);
    }
    for (const Handler &handler : g_library->handlers) {
        for (const std::vector<Byte> &signature : handler.signatures) {
            const size_t offset = handler.signatureOffset;
            if (offset + signature.size() <= head.size()
                && std::memcmp(head.data() + offset, signature.data(), signature.size()) == 0) {
                add(&handler);
                break;
            }
        }
    }
    for (const Handler &handler : g_library->handlers) {
        if (handler.isArc && !head.empty() && handler.isArc(head.data(), head.size()) == k_IsArc_Res_YES) {
            add(&handler);
        }
    }
    for (const Handler &handler : g_library->handlers) {
        if (HasExtension(handler, extensionHint)) add(&handler);
    }
    return ordered;
}

/// What 7-Zip calls the payload of a single-stream archive that stores no name:
/// "site.tar.gz" holds "site.tar", "site.tgz" holds "site.tar", "notes.gz" holds "notes".
std::string DefaultItemName(const Handler &handler, const std::string &archivePath) {
    const size_t slash = archivePath.find_last_of('/');
    const std::string name = slash == std::string::npos ? archivePath : archivePath.substr(slash + 1);
    const UString wideName = Wide(name.c_str());
    UString lower = wideName;
    lower.MakeLower_Ascii();

    const std::vector<UString> extensions = Split(handler.extensions);
    const std::vector<UString> additions = Split(handler.addExtensions);
    for (size_t i = 0; i < extensions.size(); i++) {
        UString suffix = L".";
        suffix += extensions[i];
        if (lower.Len() > suffix.Len() && UString(lower.RightPtr(suffix.Len())) == suffix) {
            UString base = wideName.Left(wideName.Len() - suffix.Len());
            if (i < additions.size() && !(additions[i] == L"*")) base += additions[i];
            return Narrow(base);
        }
    }
    const size_t dot = name.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? name + "~" : name.substr(0, dot);
}

}  // namespace

namespace {

enum class Attempt { Opened, Failed, PasswordProblem };

/// Tries each candidate format on `stream` and keeps the first that opens it.
Attempt OpenStream(IInStream *stream, const std::vector<const Handler *> &candidates, int32_t codePage,
                   OpenCallback *callbackSpec, CMyComPtr<IInArchive> &opened, const Handler *&openedHandler) {
    CMyComPtr<IArchiveOpenCallback> callback = callbackSpec;
    for (const Handler *handler : candidates) {
        CMyComPtr<IInArchive> archive;
        if (g_library->createObject(&handler->classID, &IID_IInArchive, (void **)&archive) != S_OK || !archive) {
            continue;
        }

        if (stream->Seek(0, STREAM_SEEK_SET, nullptr) != S_OK) return Attempt::Failed;
        const UInt64 scanLimit = 1 << 23;
        if (archive->Open(stream, &scanLimit, callback) == S_OK) {
            opened = archive;
            openedHandler = handler;
            return Attempt::Opened;
        }
        archive->Close();

        // The right format was found but the password was missing or wrong; trying
        // other formats would only turn that into a misleading "not an archive".
        if (callbackSpec->passwordRequested) return Attempt::PasswordProblem;
    }
    return Attempt::Failed;
}

}  // namespace

extern "C" SZArchive *sz_open(const char *path, const SZOpenOptions *options, SZError *error) {
    if (!g_library) {
        Fail(error, SZStatusLibraryMissing, "The 7-Zip library is not loaded.");
        return nullptr;
    }
    if (!path || access(path, R_OK) != 0) {
        Fail(error, SZStatusCannotOpenFile, std::string("Cannot open ") + (path ? path : "(null)") + ": "
             + std::strerror(errno));
        return nullptr;
    }

    const UString password = Wide(options ? options->password : nullptr);
    const bool hasPassword = options && options->password && options->password[0] != 0;
    const UString hint = Wide(options ? options->extensionHint : nullptr);
    const int32_t codePage = options ? options->codePage : -1;

    auto *streamSpec = new CInFileStream;
    CMyComPtr<IInStream> stream = streamSpec;
    if (!streamSpec->Open(path)) {
        Fail(error, SZStatusCannotOpenFile, std::string("Cannot open ") + path + ": " + std::strerror(errno));
        return nullptr;
    }

    const std::string fullPath = path;
    const size_t slash = fullPath.find_last_of('/');
    auto *callbackSpec = new OpenCallback;
    CMyComPtr<IArchiveOpenCallback> callbackHolder = callbackSpec;
    callbackSpec->password = password;
    callbackSpec->hasPassword = hasPassword;
    callbackSpec->folder = slash == std::string::npos ? "./" : fullPath.substr(0, slash + 1);
    callbackSpec->name = Wide(slash == std::string::npos ? path : path + slash + 1);

    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInArchive> volumes;
    const Handler *handler = nullptr;
    Attempt attempt = OpenStream(stream, Candidates(ReadHead(stream, kHeadSize), hint), codePage,
                                 callbackSpec, archive, handler);

    // Joined volumes: open whatever the joined stream holds.
    if (attempt == Attempt::Opened && handler->name == L"Split") {
        volumes = archive;
        archive.Release();
        CMyComPtr<IInArchiveGetStream> getStream;
        volumes.QueryInterface(IID_IInArchiveGetStream, (void **)&getStream);
        CMyComPtr<ISequentialInStream> joined;
        CMyComPtr<IInStream> joinedStream;
        if (getStream && getStream->GetStream(0, &joined) == S_OK && joined) {
            joined.QueryInterface(IID_IInStream, (void **)&joinedStream);
        }
        attempt = Attempt::Failed;
        if (joinedStream) {
            // The joined stream's name has no volume number: "a.7z.001" holds "a.7z".
            UString inner = callbackSpec->name;
            const int dot = inner.ReverseFind(L'.');
            UString innerHint;
            if (dot > 0) {
                inner.DeleteFrom((unsigned)dot);
                const int innerDot = inner.ReverseFind(L'.');
                if (innerDot >= 0) innerHint = inner.Ptr((unsigned)innerDot + 1);
            }
            std::vector<const Handler *> candidates = Candidates(ReadHead(joinedStream, kHeadSize), innerHint);
            candidates.erase(std::remove_if(candidates.begin(), candidates.end(),
                                            [](const Handler *h) { return h->name == L"Split"; }),
                             candidates.end());
            attempt = OpenStream(joinedStream, candidates, codePage, callbackSpec, archive, handler);
        }
        if (attempt != Attempt::Opened) volumes->Close();
    }

    if (attempt == Attempt::PasswordProblem) {
        if (!hasPassword) {
            Fail(error, SZStatusPasswordRequired, "This archive is password protected.");
        } else {
            Fail(error, SZStatusWrongPassword, "The password is incorrect.");
        }
        return nullptr;
    }
    if (attempt != Attempt::Opened) {
        Fail(error, SZStatusNotAnArchive, std::string("Is not an archive: ") + path);
        return nullptr;
    }

    auto *opened = new SZArchive();
    opened->archive = archive;
    opened->volumes = volumes;
    opened->handler = handler;
    opened->path = path;
    opened->formatName = Narrow(handler->name);
    opened->headersEncrypted = callbackSpec->passwordRequested;
    opened->password = password;
    opened->hasPassword = hasPassword;
    opened->defaultItemName = DefaultItemName(*handler, opened->path);
    opened->codePage = codePage;
    if (options && options->fallbackCodePage > 0) opened->fallbackCodePage = options->fallbackCodePage;

    NCOM::CPropVariant prop;
    if (archive->GetArchiveProperty(kpidComment, &prop) == S_OK && prop.vt == VT_BSTR && prop.bstrVal) {
        const UString comment = prop.bstrVal;
        if (!comment.IsEmpty()) {
            opened->comment = Narrow(comment);
            opened->hasComment = true;
        }
    }
    return opened;
}

extern "C" void sz_close(SZArchive *archive) {
    if (!archive) return;
    if (archive->archive) archive->archive->Close();
    if (archive->volumes) archive->volumes->Close();
    // Overwrite the copy of the password before the memory goes back to the heap.
    for (unsigned i = 0; i < archive->password.Len(); i++) archive->password.ReplaceOneCharAtPos(i, L'\0');
    delete archive;
}

// MARK: - Properties

namespace SZBridge {

bool GetBoolProperty(IInArchive *archive, UInt32 index, PROPID id, bool fallback) {
    NCOM::CPropVariant prop;
    if (archive->GetProperty(index, id, &prop) != S_OK || prop.vt != VT_BOOL) return fallback;
    return prop.boolVal != VARIANT_FALSE;
}

bool GetUInt64Property(IInArchive *archive, UInt32 index, PROPID id, UInt64 &value) {
    NCOM::CPropVariant prop;
    if (archive->GetProperty(index, id, &prop) != S_OK) return false;
    return ConvertPropVariantToUInt64(prop, value);
}

bool GetUInt32Property(IInArchive *archive, UInt32 index, PROPID id, UInt32 &value) {
    NCOM::CPropVariant prop;
    if (archive->GetProperty(index, id, &prop) != S_OK || prop.vt != VT_UI4) return false;
    value = prop.ulVal;
    return true;
}

bool GetStringProperty(IInArchive *archive, UInt32 index, PROPID id, UString &value) {
    NCOM::CPropVariant prop;
    if (archive->GetProperty(index, id, &prop) != S_OK || prop.vt != VT_BSTR || !prop.bstrVal) return false;
    value = prop.bstrVal;
    return true;
}

/// Names written before UTF-8 was usual are in whatever code page the machine that
/// made the archive used, and nothing in the archive says which.
///
/// 7-Zip hands back each byte it could not read as UTF-8 as a marker character, from
/// which the original bytes can be recovered exactly. A name holding such markers is
/// decoded with the code page the user chose, or failing that a likely one. A name
/// that reads as UTF-8 is left alone unless the user has said what the names are in.
static UString DecodedName(SZArchive *archive, const UString &path) {
    bool undecodable = false;
    bool beyondASCII = false;
    for (unsigned i = 0; i < path.Len(); i++) {
        const wchar_t c = path[i];
        if (c >= 0xEF80 && c <= 0xEFFF) undecodable = true;
        if (c >= 0x80) beyondASCII = true;
    }
    const bool chosen = archive->codePage > 0 && archive->codePage != 65001;
    if (!undecodable && !(chosen && beyondASCII)) return path;

    const unsigned codePage = (unsigned)(chosen ? archive->codePage : archive->fallbackCodePage);
    // The bytes as they are in the archive: a marker stands for one byte, and
    // anything that did read as UTF-8 was those UTF-8 bytes.
    std::string raw;
    UString run;
    for (unsigned i = 0; i < path.Len(); i++) {
        const wchar_t c = path[i];
        if (c >= 0xEF80 && c <= 0xEFFF) {
            raw += Narrow(run);
            run.Empty();
            raw += (char)(unsigned char)(c & 0xFF);
        } else {
            run += c;
        }
    }
    raw += Narrow(run);

    std::string utf8;
    if (!DecodeLegacyName(raw, codePage, utf8) || utf8.empty()) return path;
    return Wide(utf8.c_str());
}

UString ItemPath(SZArchive *archive, UInt32 index) {
    UString path;
    if (GetStringProperty(archive->archive, index, kpidPath, path) && !path.IsEmpty()) {
        return DecodedName(archive, path);
    }
    return Wide(archive->defaultItemName.c_str());
}

bool ItemIsDirectory(IInArchive *archive, UInt32 index) {
    return GetBoolProperty(archive, index, kpidIsDir);
}

bool ItemPosixMode(IInArchive *archive, UInt32 index, UInt32 &mode) {
    UInt32 value = 0;
    if (GetUInt32Property(archive, index, kpidPosixAttrib, value)) {
        mode = value;
        return true;
    }
    if (GetUInt32Property(archive, index, kpidAttrib, value) && (value & FILE_ATTRIBUTE_UNIX_EXTENSION)) {
        mode = value >> 16;
        return true;
    }
    return false;
}

bool ItemIsSymlink(IInArchive *archive, UInt32 index) {
    UString link;
    if (GetStringProperty(archive, index, kpidSymLink, link) && !link.IsEmpty()) return true;
    UInt32 mode = 0;
    return ItemPosixMode(archive, index, mode) && S_ISLNK(mode);
}

bool ItemModified(IInArchive *archive, UInt32 index, int64_t &seconds, int32_t &nanoseconds) {
    NCOM::CPropVariant prop;
    if (archive->GetProperty(index, kpidMTime, &prop) != S_OK || prop.vt != VT_FILETIME) return false;
    const UInt64 ticks = ((UInt64)prop.filetime.dwHighDateTime << 32) | prop.filetime.dwLowDateTime;
    if (ticks == 0) return false;
    // FILETIME counts 100 ns intervals from 1601; Unix time counts seconds from 1970.
    const Int64 sinceUnixEpoch = (Int64)ticks - (Int64)116444736000000000LL;
    Int64 wholeSeconds = sinceUnixEpoch / 10000000;
    Int64 remainder = sinceUnixEpoch % 10000000;
    if (remainder < 0) {
        remainder += 10000000;
        wholeSeconds -= 1;
    }
    seconds = wholeSeconds;
    nanoseconds = (int32_t)(remainder * 100);
    return true;
}

// MARK: - Paths

bool SanitizePath(const std::string &raw, std::string &safe) {
    std::string text = raw;
    std::replace(text.begin(), text.end(), '\\', '/');

    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= text.size()) {
        const size_t slash = text.find('/', start);
        const std::string part = text.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        if (part == "..") return false;
        const bool isDrive = parts.empty() && part.size() == 2 && part[1] == ':' && std::isalpha((unsigned char)part[0]);
        if (!part.empty() && part != "." && !isDrive) parts.push_back(part);
        if (slash == std::string::npos) break;
        start = slash + 1;
    }

    safe.clear();
    for (size_t i = 0; i < parts.size(); i++) {
        if (i) safe += '/';
        safe += parts[i];
    }
    return true;
}

bool PathExists(const std::string &path) {
    struct stat info;
    return lstat(path.c_str(), &info) == 0;
}

bool IsDirectoryPath(const std::string &path) {
    struct stat info;
    return stat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode);
}

bool IsSymlinkPath(const std::string &path) {
    struct stat info;
    return lstat(path.c_str(), &info) == 0 && S_ISLNK(info.st_mode);
}

std::string UniquePath(const std::string &path) {
    if (!PathExists(path)) return path;
    const size_t slash = path.find_last_of('/');
    const std::string directory = slash == std::string::npos ? "" : path.substr(0, slash + 1);
    const std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
    const size_t dot = name.find_last_of('.');
    const bool hasExtension = dot != std::string::npos && dot > 0;
    const std::string base = hasExtension ? name.substr(0, dot) : name;
    const std::string extension = hasExtension ? name.substr(dot) : "";
    for (int counter = 2; counter < 100000; counter++) {
        const std::string candidate = directory + base + " " + std::to_string(counter) + extension;
        if (!PathExists(candidate)) return candidate;
    }
    return path + "-" + std::to_string(getpid());
}

bool NoLinkInParents(const std::string &root, const std::string &relative) {
    std::string current = root;
    size_t start = 0;
    while (true) {
        const size_t slash = relative.find('/', start);
        if (slash == std::string::npos) return true;
        current += "/" + relative.substr(start, slash - start);
        if (IsSymlinkPath(current)) return false;
        start = slash + 1;
    }
}

bool MakeDirectories(const std::string &path) {
    if (path.empty() || IsDirectoryPath(path)) return true;
    // Walks down from the top rather than recursing up from the bottom: an archive can
    // name a path thousands of folders deep, and recursion that deep overflows the stack.
    size_t position = 0;
    while (position != std::string::npos) {
        position = path.find('/', position + 1);
        const std::string prefix = path.substr(0, position);
        if (prefix.empty()) continue;
        if (mkdir(prefix.c_str(), 0755) != 0 && errno != EEXIST && !IsDirectoryPath(prefix)) return false;
    }
    return IsDirectoryPath(path);
}

bool UsablePermissions(UInt32 mode, mode_t &permissions) {
    // Zip entries written by tools that know nothing of Unix claim a mode of zero,
    // which would leave the owner unable to read their own file.
    if ((mode & 0777) == 0) return false;
    static const mode_t mask = [] {
        const mode_t current = umask(0);
        umask(current);
        return current;
    }();
    permissions = (mode_t)(mode & 0777) & ~mask;
    return true;
}

// MARK: - Progress

void Progress::SetTotal(UInt64 value) {
    std::lock_guard<std::mutex> guard(lock);
    total = value;
}

void Progress::SetCompleted(UInt64 value) {
    std::lock_guard<std::mutex> guard(lock);
    completed = value;
}

void Progress::SetCurrent(const std::string &path) {
    std::lock_guard<std::mutex> guard(lock);
    current = path;
}

UInt64 Progress::Completed() {
    std::lock_guard<std::mutex> guard(lock);
    return completed;
}

bool Progress::Cancelled() {
    std::lock_guard<std::mutex> guard(lock);
    return cancelled;
}

bool Progress::Report() {
    std::lock_guard<std::mutex> guard(lock);
    if (cancelled) return false;
    if (!callback) return true;
    if (!callback(context, completed, total, current.c_str())) cancelled = true;
    return !cancelled;
}

}  // namespace SZBridge

// MARK: - Listing

extern "C" void sz_archive_info(SZArchive *archive, SZArchiveInfo *info) {
    if (!archive || !info) return;
    std::memset(info, 0, sizeof(*info));
    info->formatName = archive->formatName.c_str();
    info->headersEncrypted = archive->headersEncrypted;
    info->comment = archive->hasComment ? archive->comment.c_str() : nullptr;

    NCOM::CPropVariant size;
    UInt64 physical = 0;
    if (archive->archive->GetArchiveProperty(kpidPhySize, &size) == S_OK && ConvertPropVariantToUInt64(size, physical)) {
        info->physicalSize = physical;
    } else {
        struct stat stats;
        if (stat(archive->path.c_str(), &stats) == 0) info->physicalSize = (uint64_t)stats.st_size;
    }

    NCOM::CPropVariant solid;
    info->isSolid = archive->archive->GetArchiveProperty(kpidSolid, &solid) == S_OK
        && solid.vt == VT_BOOL && solid.boolVal != VARIANT_FALSE;
}

extern "C" uint32_t sz_item_count(SZArchive *archive) {
    if (!archive) return 0;
    UInt32 count = 0;
    archive->archive->GetNumberOfItems(&count);
    return count;
}

extern "C" bool sz_item(SZArchive *archive, uint32_t index, SZItem *item) {
    if (!archive || !item || index >= sz_item_count(archive)) return false;
    std::memset(item, 0, sizeof(*item));
    IInArchive *handle = archive->archive;

    archive->itemPath = Narrow(ItemPath(archive, index));
    item->path = archive->itemPath.c_str();
    item->isDirectory = ItemIsDirectory(handle, index);
    item->isSymlink = !item->isDirectory && ItemIsSymlink(handle, index);

    UInt64 value = 0;
    if (GetUInt64Property(handle, index, kpidSize, value)) item->size = value;
    if (GetUInt64Property(handle, index, kpidPackSize, value)) item->packedSize = value;

    int64_t seconds = 0;
    int32_t nanoseconds = 0;
    if (ItemModified(handle, index, seconds, nanoseconds)) {
        item->hasModified = true;
        item->modifiedSeconds = seconds;
        item->modifiedNanoseconds = nanoseconds;
    }

    UInt32 crc = 0;
    if (GetUInt32Property(handle, index, kpidCRC, crc)) {
        item->hasCRC = true;
        item->crc = crc;
    }

    item->encrypted = GetBoolProperty(handle, index, kpidEncrypted);

    UString method;
    if (GetStringProperty(handle, index, kpidMethod, method) && !method.IsEmpty()) {
        archive->itemMethod = Narrow(method);
        item->method = archive->itemMethod.c_str();
    }

    UInt32 mode = 0;
    if (ItemPosixMode(handle, index, mode)) {
        item->hasPosixMode = true;
        item->posixMode = mode;
    }
    return true;
}
