// SevenZipBridge.h
//
// A small C interface over 7-Zip's in-process library (7z.so), so Swift can list,
// extract, test and write archives without starting a helper process.
//
// The point of doing this in process is that nothing sensitive leaves the app. With
// the command-line tool a password had to be passed as an argument, where any other
// process running as the same user could read it for as long as the tool ran. Here a
// password only ever lives in this process's memory.
//
// Everything is synchronous and blocking; call it off the main thread. Strings are
// UTF-8. Every function that can fail fills an SZError when one is passed.

#ifndef SEVENZIP_BRIDGE_H
#define SEVENZIP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum SZStatus {
    SZStatusOK = 0,
    SZStatusLibraryMissing,
    SZStatusCannotOpenFile,
    SZStatusNotAnArchive,
    SZStatusPasswordRequired,
    SZStatusWrongPassword,
    SZStatusDataError,
    SZStatusUnsupported,
    SZStatusCancelled,
    SZStatusWriteError,
    SZStatusUnsafePath,
    SZStatusFailed,
} SZStatus;

typedef struct SZError {
    SZStatus status;
    char message[1024];
} SZError;

// MARK: - Library

/// Loads 7z.so from `libraryPath`. Later calls return the first result.
SZStatus sz_load(const char *libraryPath, SZError *error);

/// True once sz_load has succeeded.
bool sz_is_loaded(void);

/// The 7-Zip version this bridge was built against, such as "25.01".
const char *sz_version(void);

/// Handler names the loaded library offers, for diagnostics and tests.
uint32_t sz_format_count(void);
const char *sz_format_name(uint32_t index);
bool sz_format_can_write(uint32_t index);

// MARK: - Reading

typedef struct SZArchive SZArchive;

typedef struct SZOpenOptions {
    /// NULL when none is known yet.
    const char *password;
    /// The file's extension without the dot, used to break ties when the content
    /// alone does not identify the format. May be NULL.
    const char *extensionHint;
    /// A code page for archives that store names without declaring an encoding,
    /// such as old zip files. Negative means automatic.
    int32_t codePage;
    /// The code page for names that are not valid UTF-8 when `codePage` leaves the
    /// choice open. Zero means 437, which is what the zip format itself specifies.
    int32_t fallbackCodePage;
} SZOpenOptions;

SZArchive *sz_open(const char *path, const SZOpenOptions *options, SZError *error);
void sz_close(SZArchive *archive);

typedef struct SZArchiveInfo {
    /// The handler's own name: "zip", "7z", "Rar5", "tar", "gzip" and so on.
    const char *formatName;
    uint64_t physicalSize;
    bool isSolid;
    /// A password was needed just to read the list of contents.
    bool headersEncrypted;
    /// NULL when the archive has no comment.
    const char *comment;
    /// For an archive in several volumes, how many there are besides the one opened.
    uint32_t otherVolumeCount;
} SZArchiveInfo;

/// Strings in `info` stay valid until the archive is closed.
void sz_archive_info(SZArchive *archive, SZArchiveInfo *info);

/// The file name of another volume of the archive, in the same folder as the one
/// opened. NULL when `index` is out of range. Valid until the archive is closed.
const char *sz_archive_volume_name(SZArchive *archive, uint32_t index);

uint32_t sz_item_count(SZArchive *archive);

typedef struct SZItem {
    /// Valid until the next call to sz_item on the same archive.
    const char *path;
    bool isDirectory;
    bool isSymlink;
    uint64_t size;
    uint64_t packedSize;
    bool hasModified;
    int64_t modifiedSeconds;
    int32_t modifiedNanoseconds;
    bool hasCRC;
    uint32_t crc;
    bool encrypted;
    /// Valid until the next call to sz_item. NULL when unknown.
    const char *method;
    bool hasPosixMode;
    uint32_t posixMode;
} SZItem;

bool sz_item(SZArchive *archive, uint32_t index, SZItem *item);

// MARK: - Extracting and testing

/// Reports progress. Return false to cancel the operation.
typedef bool (*SZProgressCallback)(void *context, uint64_t completed, uint64_t total,
                                   const char *currentPath);

typedef enum SZOverwrite {
    SZOverwriteReplace = 0,
    SZOverwriteSkip,
    SZOverwriteRenameNew,
    SZOverwriteRenameExisting,
} SZOverwrite;

typedef struct SZExtractOptions {
    /// The folder to write into. Ignored when testing.
    const char *destination;
    const char *password;
    SZOverwrite overwrite;
    /// Drop folder structure and write every file straight into the destination.
    bool flatten;
    /// Decode and verify everything without writing anything.
    bool testOnly;
    /// Create every symbolic link as the archive has it, wherever it points. Only
    /// for a private folder whose contents go straight back into an archive: a link
    /// that leads outside is otherwise refused, since whatever follows it would be
    /// reading or writing somewhere the user never chose.
    bool keepLinksAsStored;
} SZExtractOptions;

typedef struct SZExtractSummary {
    uint64_t filesProcessed;
    uint64_t bytesProcessed;
    /// Symbolic links that were not created because they pointed outside the destination.
    uint32_t linksRefused;
} SZExtractSummary;

/// `indices` NULL means every item. Indices need not be sorted.
SZStatus sz_extract(SZArchive *archive, const uint32_t *indices, uint32_t count,
                    const SZExtractOptions *options,
                    SZProgressCallback progress, void *context,
                    SZExtractSummary *summary, SZError *error);

// MARK: - Writing

typedef struct SZNewItem {
    /// Where the item goes inside the archive, with "/" separators.
    const char *archivePath;
    /// The file, folder or symbolic link on disk. Links are stored as links.
    const char *diskPath;
} SZNewItem;

typedef struct SZRename {
    uint32_t index;
    const char *newPath;
} SZRename;

typedef struct SZWriteOptions {
    /// A handler name: "7z", "zip", "tar", "gzip", "bzip2", "xz" or "zstd".
    /// Ignored when writing from a source archive, which keeps its own format.
    const char *formatName;
    /// 0 to 9. Negative leaves the format's default.
    int32_t level;
    /// NULL or empty for no encryption.
    const char *password;
    /// Zip only: "AES256", "AES192", "AES128" or "ZipCrypto". NULL means AES256.
    const char *zipEncryption;
    /// 7z only: encrypt the file names as well as the contents.
    bool encryptHeaders;
    /// 7z only: -1 for the default, 0 for off, 1 for on.
    int32_t solid;
} SZWriteOptions;

/// Writes a complete archive to `outputPath`, which should be a new file beside the
/// final destination. When `source` is given, its items are carried over, except those
/// listed in `removed`, with `renames` applied, and the output keeps the source's
/// format. `added` items are appended.
SZStatus sz_write(SZArchive *source,
                  const uint32_t *removed, uint32_t removedCount,
                  const SZRename *renames, uint32_t renameCount,
                  const SZNewItem *added, uint32_t addedCount,
                  const char *outputPath, const SZWriteOptions *options,
                  SZProgressCallback progress, void *context,
                  SZError *error);

#ifdef __cplusplus
}
#endif

#endif
