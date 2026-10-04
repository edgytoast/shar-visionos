#ifndef SHAR_ARCHIVE_EXTRACTOR_H
#define SHAR_ARCHIVE_EXTRACTOR_H

#include <stdint.h>

// Called as extraction proceeds, with the number of archive (compressed) bytes consumed so far.
typedef void (*SharExtractProgress)(void *context, int64_t archiveBytesRead);

// Extracts every directory and regular file in `archivePath` (RAR, ZIP, 7z, tar, ...) under
// `destination`. Entries with absolute paths or ".." components are rejected rather than
// written outside `destination`. Returns NULL on success, or an error message the caller frees.
char *SharExtractArchive(const char *archivePath, const char *destination, SharExtractProgress progress,
                         void *context);

#endif
