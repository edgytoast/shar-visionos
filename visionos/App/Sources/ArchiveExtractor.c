#include "ArchiveExtractor.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

// libarchive ships in the visionOS SDK (usr/lib/libarchive.tbd) but without headers. These are
// the stable public declarations from libarchive 3.x's archive.h and archive_entry.h
// (github.com/libarchive/libarchive, libarchive/archive.h and libarchive/archive_entry.h).
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t blockSize);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int64_t archive_filter_bytes(struct archive *, int filter);
const char *archive_error_string(struct archive *);
int archive_read_free(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);

#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_WARN (-20)
#define AE_IFMT 0170000
#define AE_IFREG 0100000
#define AE_IFDIR 0040000

static char *Format(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    char *message = NULL;
    vasprintf(&message, format, arguments);
    va_end(arguments);
    return message;
}

// Normalises an entry path in place (Windows separators, leading "./"). Returns 0 if it would
// escape the destination.
static int MakeSafeRelative(char *path)
{
    for (char *p = path; *p; ++p)
        if (*p == '\\') *p = '/';
    if (path[0] == '/') return 0;
    for (const char *segment = path; *segment;)
    {
        const char *end = strchr(segment, '/');
        const size_t length = end ? (size_t)(end - segment) : strlen(segment);
        if (length == 2 && segment[0] == '.' && segment[1] == '.') return 0;
        segment += length + (end ? 1 : 0);
    }
    return 1;
}

static int MakeDirectories(char *path)
{
    for (char *p = path + 1; *p; ++p)
    {
        if (*p != '/') continue;
        *p = '\0';
        const int failed = mkdir(path, 0755) != 0 && errno != EEXIST;
        *p = '/';
        if (failed) return 0;
    }
    return mkdir(path, 0755) == 0 || errno == EEXIST;
}

char *SharExtractArchive(const char *archivePath, const char *destination, SharExtractProgress progress,
                         void *context)
{
    struct archive *archive = archive_read_new();
    archive_read_support_filter_all(archive);
    archive_read_support_format_all(archive);
    if (archive_read_open_filename(archive, archivePath, 1 << 20) != ARCHIVE_OK)
    {
        char *error = Format("Couldn't open the archive: %s", archive_error_string(archive));
        archive_read_free(archive);
        return error;
    }

    const size_t bufferSize = 1 << 20;
    char *buffer = malloc(bufferSize);
    char *error = NULL;
    struct archive_entry *entry = NULL;
    int status;
    while ((status = archive_read_next_header(archive, &entry)) == ARCHIVE_OK || status == ARCHIVE_WARN)
    {
        char *relative = strdup(archive_entry_pathname(entry));
        if (!MakeSafeRelative(relative))
        {
            error = Format("The archive contains an unsafe path: %s", relative);
            free(relative);
            break;
        }
        char *target = Format("%s/%s", destination, relative);
        free(relative);

        const mode_t type = archive_entry_filetype(entry) & AE_IFMT;
        if (type == AE_IFDIR)
        {
            if (!MakeDirectories(target)) error = Format("Couldn't create folder %s", target);
        }
        else if (type == AE_IFREG)
        {
            char *slash = strrchr(target, '/');
            if (slash)
            {
                *slash = '\0';
                const int made = MakeDirectories(target);
                *slash = '/';
                if (!made) error = Format("Couldn't create the folder for %s", target);
            }
            FILE *file = error ? NULL : fopen(target, "wb");
            if (!error && !file) error = Format("Couldn't write %s: %s", target, strerror(errno));
            ssize_t count = 0;
            while (file && (count = archive_read_data(archive, buffer, bufferSize)) > 0)
            {
                if (fwrite(buffer, 1, (size_t)count, file) != (size_t)count)
                {
                    error = Format("Couldn't write %s (disk full?)", target);
                    break;
                }
            }
            if (file && count < 0 && !error)
                error = Format("Couldn't extract %s: %s", target, archive_error_string(archive));
            if (file) fclose(file);
        }
        free(target);
        if (error) break;
        if (progress) progress(context, archive_filter_bytes(archive, -1));
    }
    if (!error && status != ARCHIVE_EOF)
        error = Format("The archive is damaged or unsupported: %s", archive_error_string(archive));

    free(buffer);
    archive_read_free(archive);
    return error;
}
