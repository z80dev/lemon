/*
 * lemon_confined_fs - descriptor-bound file operations for LemonCore.ConfinedFS.
 *
 * OTP has no openat/O_NOFOLLOW, so path-based checks followed by a separate
 * path-based open, rename or unlink can be redirected by a concurrent writer
 * who swaps a checked directory for a symlink. This helper runs as an Erlang
 * port and performs every operation relative to directory descriptors:
 *
 *   - a session opens one trusted root directory (OPEN_ROOT, symlinks in the
 *     root path itself are followed: the operator chose it);
 *   - every path below a descriptor is a list of single components, each
 *     validated here (non-empty, no "/", no NUL, not "." or "..");
 *   - directories are walked with openat(O_DIRECTORY|O_NOFOLLOW) one
 *     component at a time (Linux first tries openat2 with RESOLVE_BENEATH and
 *     RESOLVE_NO_SYMLINKS), so a symlink anywhere below the root is refused;
 *   - leaf operations use the *at() calls on the walked descriptor with
 *     no-follow semantics, so a later swap of a parent path cannot move them.
 *
 * Framing: Erlang {packet, 4} on stdin/stdout. A request is <<Op:8, Body>>;
 * a reply is <<0, Body>> on success or <<1, ErrorName>> on failure. Integers
 * are big-endian; byte strings are <<Len:32, Bytes>>. The helper never writes
 * anything else to stdout and exits when stdin closes.
 */

#if defined(__linux__)
#define _GNU_SOURCE
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/syscall.h>
#if defined(__has_include)
#if __has_include(<linux/openat2.h>)
#include <linux/openat2.h>
#define LCFS_HAVE_OPENAT2 1
#endif
#endif
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
#endif

#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif

#define MAX_FRAME (512u * 1024u * 1024u)
#define MAX_HANDLES 1024
#define MAX_NAME 255
#define MAX_TREE_DEPTH 256
#define MAX_TREE_PASSES 8

enum op {
    OP_OPEN_ROOT = 1,
    OP_OPEN_DIR = 2,
    OP_CLOSE = 3,
    OP_STAT = 4,
    OP_LIST = 5,
    OP_READ = 6,
    OP_WRITE = 7,
    OP_MKDIR = 8,
    OP_UNLINK = 9,
    OP_RMDIR = 10,
    OP_REMOVE_TREE = 11,
    OP_RENAME = 12,
    OP_CHMOD = 13,
    OP_SYMLINK = 14,
    OP_READLINK = 15,
    OP_APPEND = 16
};

/* OP_WRITE modes. */
enum write_how { HOW_CREATE = 1, HOW_REPLACE = 2, HOW_OVERWRITE = 3 };

/* Option flags shared by READ, WRITE and UNLINK. */
#define FLAG_EXPECT_IDENTITY 1u
#define FLAG_EXPECT_ABSENT 2u
#define FLAG_MODE_EXACT 4u
#define FLAG_SYNC 8u
#define FLAG_PRESERVE_MODE 16u
#define FLAG_PREFIX 32u
#define FLAG_CREATE 64u

/* OP_OPEN_DIR flags. */
#define DIR_CREATE 1u

/* OP_RENAME flags. */
#define RENAME_FLAG_NOREPLACE 1u

/* Error names that are not errno values. */
#define E_SYMLINK "symlink"
#define E_NOT_REGULAR "not_regular"
#define E_CHANGED "changed"
#define E_TOO_LARGE "too_large"
#define E_BAD_REQUEST "bad_request"
#define E_BAD_HANDLE "bad_handle"
#define E_TOO_MANY "too_many"

static int handles[MAX_HANDLES + 1];

/* The process umask, read once at start (umask(2) has no query form). */
static mode_t process_umask;

/* ------------------------------------------------------------------------ */
/* Buffers                                                                   */
/* ------------------------------------------------------------------------ */

struct in {
    const uint8_t *p;
    size_t n;
    int bad;
};

struct out {
    uint8_t *buf;
    size_t len;
    size_t cap;
};

static void die(void) { _exit(70); }

static void out_reserve(struct out *o, size_t extra) {
    if (extra > MAX_FRAME || o->len > MAX_FRAME - extra) die();
    if (o->len + extra <= o->cap) return;
    size_t cap = o->cap ? o->cap : 256;
    while (cap < o->len + extra) cap *= 2;
    uint8_t *buf = realloc(o->buf, cap);
    if (!buf) die();
    o->buf = buf;
    o->cap = cap;
}

static void put_bytes_raw(struct out *o, const void *data, size_t len) {
    out_reserve(o, len);
    if (len) memcpy(o->buf + o->len, data, len);
    o->len += len;
}

static void put_u8(struct out *o, uint8_t v) { put_bytes_raw(o, &v, 1); }

static void put_u32(struct out *o, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    put_bytes_raw(o, b, 4);
}

static void put_u64(struct out *o, uint64_t v) {
    put_u32(o, (uint32_t)(v >> 32));
    put_u32(o, (uint32_t)v);
}

static void put_bin(struct out *o, const void *data, size_t len) {
    if (len > UINT32_MAX) die();
    put_u32(o, (uint32_t)len);
    put_bytes_raw(o, data, len);
}

static uint32_t get_u32(struct in *in) {
    if (in->bad || in->n < 4) {
        in->bad = 1;
        return 0;
    }
    uint32_t v = ((uint32_t)in->p[0] << 24) | ((uint32_t)in->p[1] << 16) |
                 ((uint32_t)in->p[2] << 8) | (uint32_t)in->p[3];
    in->p += 4;
    in->n -= 4;
    return v;
}

static uint64_t get_u64(struct in *in) {
    uint64_t hi = get_u32(in);
    uint64_t lo = get_u32(in);
    return (hi << 32) | lo;
}

static const uint8_t *get_bin(struct in *in, size_t *len) {
    uint32_t l = get_u32(in);
    if (in->bad || in->n < l) {
        in->bad = 1;
        *len = 0;
        return NULL;
    }
    const uint8_t *p = in->p;
    in->p += l;
    in->n -= l;
    *len = l;
    return p;
}

/* A single path component: non-empty (unless allow_empty), at most
 * MAX_NAME bytes, no "/", no NUL, not "." or "..". Copied NUL-terminated. */
static int get_name(struct in *in, char name[MAX_NAME + 1], int allow_empty) {
    size_t len;
    const uint8_t *p = get_bin(in, &len);
    if (in->bad) return -1;
    if (len == 0) {
        if (!allow_empty) return -1;
        name[0] = '\0';
        return 0;
    }
    if (len > MAX_NAME) return -1;
    for (size_t i = 0; i < len; i++) {
        if (p[i] == '/' || p[i] == '\0') return -1;
    }
    if ((len == 1 && p[0] == '.') || (len == 2 && p[0] == '.' && p[1] == '.')) return -1;
    memcpy(name, p, len);
    name[len] = '\0';
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Errors and replies                                                        */
/* ------------------------------------------------------------------------ */

static const char *errno_name(int e) {
    switch (e) {
    case ENOENT: return "enoent";
    case EEXIST: return "eexist";
    case EACCES: return "eacces";
    case EPERM: return "eperm";
    case ENOTDIR: return "enotdir";
    case EISDIR: return "eisdir";
    case ELOOP: return E_SYMLINK;
    case ENOTEMPTY: return "enotempty";
    case EXDEV: return "exdev";
    case ENOSPC: return "enospc";
    case EROFS: return "erofs";
    case EBUSY: return "ebusy";
    case EMFILE: return "emfile";
    case ENFILE: return "enfile";
    case ENAMETOOLONG: return "enametoolong";
    case EINVAL: return "einval";
    case ENXIO: return "enxio";
    case ETXTBSY: return "etxtbsy";
    case EFBIG: return "efbig";
    case ENOMEM: return "enomem";
    case EIO: return "eio";
    case ENOTSUP: return "enotsup";
#if defined(EOPNOTSUPP) && EOPNOTSUPP != ENOTSUP
    case EOPNOTSUPP: return "enotsup";
#endif
#ifdef EDQUOT
    case EDQUOT: return "edquot";
#endif
    case ENOSYS: return "enotsup";
    case EAGAIN: return "eagain";
    case EBADF: return E_BAD_HANDLE;
    default: return "eio";
    }
}

static void reply_error(struct out *o, const char *name) {
    o->len = 0;
    put_u8(o, 1);
    put_bytes_raw(o, name, strlen(name));
}

static void reply_errno(struct out *o, int e) { reply_error(o, errno_name(e)); }

static void reply_ok(struct out *o) {
    o->len = 0;
    put_u8(o, 0);
}

enum ftype { T_REGULAR = 1, T_DIRECTORY = 2, T_SYMLINK = 3, T_OTHER = 4 };

static uint8_t file_type(mode_t mode) {
    if (S_ISREG(mode)) return T_REGULAR;
    if (S_ISDIR(mode)) return T_DIRECTORY;
    if (S_ISLNK(mode)) return T_SYMLINK;
    return T_OTHER;
}

/* 49 bytes: type, permission bits, size, dev, ino, nlink, uid, mtime s/ns. */
static void put_stat(struct out *o, const struct stat *st) {
    put_u8(o, file_type(st->st_mode));
    put_u32(o, (uint32_t)(st->st_mode & 07777));
    put_u64(o, (uint64_t)st->st_size);
    put_u64(o, (uint64_t)st->st_dev);
    put_u64(o, (uint64_t)st->st_ino);
    put_u32(o, (uint32_t)st->st_nlink);
    put_u32(o, (uint32_t)st->st_uid);
#if defined(__APPLE__)
    put_u64(o, (uint64_t)(int64_t)st->st_mtimespec.tv_sec);
    put_u32(o, (uint32_t)st->st_mtimespec.tv_nsec);
#else
    put_u64(o, (uint64_t)(int64_t)st->st_mtim.tv_sec);
    put_u32(o, (uint32_t)st->st_mtim.tv_nsec);
#endif
}

static int same_object(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

/* ------------------------------------------------------------------------ */
/* Handles                                                                   */
/* ------------------------------------------------------------------------ */

static int handle_fd(uint32_t h) {
    if (h == 0 || h > MAX_HANDLES) return -1;
    return handles[h];
}

static int handle_put(int fd) {
    for (uint32_t h = 1; h <= MAX_HANDLES; h++) {
        if (handles[h] < 0) {
            handles[h] = fd;
            return (int)h;
        }
    }
    return -1;
}

/* ------------------------------------------------------------------------ */
/* Descriptor-relative primitives                                            */
/* ------------------------------------------------------------------------ */

/* Classify a failed no-follow open of `name` below `dir`. */
static int classify_open_error(int dir, const char *name, int err) {
    if (err == ELOOP || err == ENOTDIR || err == EMLINK) {
        struct stat st;
        if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)) return ELOOP;
    }
    return err;
}

/* One directory component, never following a symlink. */
static int open_dir_component(int dir, const char *name) {
    int fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) errno = classify_open_error(dir, name, errno);
    return fd;
}

#ifdef LCFS_HAVE_OPENAT2
/* Linux fast path: one openat2 call for the whole relative path, beneath
 * `dir` and with no symlink anywhere. Returns -2 when the caller should fall
 * back to the per-component walk (unsupported kernel/seccomp, or an error
 * that the walk reports more precisely). */
static int openat2_beneath(int dir, char names[][MAX_NAME + 1], uint32_t count) {
    char path[PATH_MAX];
    size_t len = 0;
    for (uint32_t i = 0; i < count; i++) {
        size_t n = strlen(names[i]);
        if (len + n + 2 > sizeof(path)) return -2;
        if (i) path[len++] = '/';
        memcpy(path + len, names[i], n);
        len += n;
    }
    path[len] = '\0';
    struct open_how how;
    memset(&how, 0, sizeof(how));
    how.flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    how.resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
    long fd = syscall(SYS_openat2, dir, path, &how, sizeof(how));
    if (fd >= 0) return (int)fd;
    return -2;
}
#endif

/* Walk `count` components below `dir`; create missing ones when `create`. */
static int walk_dirs(int dir, char names[][MAX_NAME + 1], uint32_t count, int create, mode_t mode) {
    if (count == 0) return openat(dir, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
#ifdef LCFS_HAVE_OPENAT2
    if (!create) {
        int fd = openat2_beneath(dir, names, count);
        if (fd >= 0) return fd;
    }
#endif
    int cur = dir;
    for (uint32_t i = 0; i < count; i++) {
        int fd = open_dir_component(cur, names[i]);
        if (fd < 0 && errno == ENOENT && create) {
            if (mkdirat(cur, names[i], mode) < 0 && errno != EEXIST) {
                int e = errno;
                if (cur != dir) close(cur);
                errno = e;
                return -1;
            }
            fd = open_dir_component(cur, names[i]);
        }
        int e = errno;
        if (cur != dir) close(cur);
        if (fd < 0) {
            errno = e;
            return -1;
        }
        cur = fd;
    }
    return cur;
}

/* chmod without following a final symlink (which is refused). */
static int chmod_at(int dir, const char *name, mode_t mode) {
#if defined(__APPLE__)
    struct stat st;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) < 0) return -1;
    if (S_ISLNK(st.st_mode)) {
        errno = ELOOP;
        return -1;
    }
    return fchmodat(dir, name, mode, AT_SYMLINK_NOFOLLOW);
#elif defined(__linux__)
    int fd = openat(dir, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    if (S_ISLNK(st.st_mode)) {
        close(fd);
        errno = ELOOP;
        return -1;
    }
    char proc[64];
    snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);
    int rc = chmod(proc, mode);
    int e = errno;
    close(fd);
    errno = e;
    return rc;
#else
    (void)dir;
    (void)name;
    (void)mode;
    errno = ENOTSUP;
    return -1;
#endif
}

static int write_all(int fd, const uint8_t *data, size_t len, off_t offset) {
    while (len > 0) {
        ssize_t n = pwrite(fd, data, len, offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        data += n;
        len -= (size_t)n;
        offset += n;
    }
    return 0;
}

static int full_sync(int fd) {
#if defined(__APPLE__) && defined(F_FULLFSYNC)
    if (fcntl(fd, F_FULLFSYNC) == 0) return 0;
#endif
    return fsync(fd);
}

/* Regular, non-symlink entry `name`: lstat first, then a no-follow,
 * non-blocking open whose descriptor must be that same object. */
static int open_regular(int dir, const char *name, int flags, struct stat *st, const char **err) {
    struct stat pre;
    if (fstatat(dir, name, &pre, AT_SYMLINK_NOFOLLOW) < 0) {
        *err = errno_name(errno);
        return -1;
    }
    if (S_ISLNK(pre.st_mode)) {
        *err = E_SYMLINK;
        return -1;
    }
    if (!S_ISREG(pre.st_mode)) {
        *err = E_NOT_REGULAR;
        return -1;
    }
    int fd = openat(dir, name, flags | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) {
        *err = errno_name(classify_open_error(dir, name, errno));
        return -1;
    }
    if (fstat(fd, st) < 0 || !S_ISREG(st->st_mode) || !same_object(st, &pre)) {
        close(fd);
        *err = E_CHANGED;
        return -1;
    }
    return fd;
}

static int expect_matches(const struct stat *st, uint32_t flags, uint64_t dev, uint64_t ino) {
    if (!(flags & FLAG_EXPECT_IDENTITY)) return 1;
    return (uint64_t)st->st_dev == dev && (uint64_t)st->st_ino == ino;
}

/* Precondition for replacing `name`: the entry is still the expected regular
 * file, or still absent. */
static const char *check_expectation(int dir, const char *name, uint32_t flags, uint64_t dev,
                                     uint64_t ino, struct stat *existing, int *exists) {
    *exists = 0;
    if (fstatat(dir, name, existing, AT_SYMLINK_NOFOLLOW) < 0) {
        if (errno != ENOENT) return errno_name(errno);
        if (flags & FLAG_EXPECT_IDENTITY) return E_CHANGED;
        return NULL;
    }
    *exists = 1;
    if (flags & FLAG_EXPECT_ABSENT) return "eexist";
    if (S_ISLNK(existing->st_mode)) return E_SYMLINK;
    if (S_ISDIR(existing->st_mode)) return "eisdir";
    if (!S_ISREG(existing->st_mode)) return E_NOT_REGULAR;
    if (!expect_matches(existing, flags, dev, ino)) return E_CHANGED;
    return NULL;
}

static int random_suffix(char *buf, size_t len) {
    static const char hex[] = "0123456789abcdef";
    uint8_t bytes[12];
#if defined(__APPLE__)
    arc4random_buf(bytes, sizeof(bytes));
#else
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < sizeof(bytes)) {
        ssize_t n = read(fd, bytes + got, sizeof(bytes) - got);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            close(fd);
            return -1;
        }
        got += (size_t)n;
    }
    close(fd);
#endif
    if (len < sizeof(bytes) * 2 + 1) return -1;
    for (size_t i = 0; i < sizeof(bytes); i++) {
        buf[2 * i] = hex[bytes[i] >> 4];
        buf[2 * i + 1] = hex[bytes[i] & 15];
    }
    buf[sizeof(bytes) * 2] = '\0';
    return 0;
}

/* Remove `name` below `dir` without following symlinks; directories are
 * emptied through their own descriptors. Owner access is added to a
 * directory that the owner cannot list or modify. */
static int remove_tree_at(int dir, const char *name, int depth) {
    struct stat st;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) < 0) return -1;
    if (!S_ISDIR(st.st_mode)) return unlinkat(dir, name, 0);
    if (depth >= MAX_TREE_DEPTH) {
        errno = ELOOP;
        return -1;
    }
    if ((st.st_mode & S_IRWXU) != S_IRWXU) {
        if (chmod_at(dir, name, (st.st_mode & 07777) | S_IRWXU) < 0) return -1;
    }
    for (int pass = 0; pass < MAX_TREE_PASSES; pass++) {
        int fd = open_dir_component(dir, name);
        if (fd < 0) return -1;
        struct stat now;
        if (fstat(fd, &now) < 0 || !same_object(&now, &st)) {
            close(fd);
            errno = EBUSY;
            return -1;
        }
        int listfd = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        DIR *d = listfd >= 0 ? fdopendir(listfd) : NULL;
        if (!d) {
            int e = errno;
            if (listfd >= 0) close(listfd);
            close(fd);
            errno = e;
            return -1;
        }
        /* Collect names first: removing entries while reading a directory
         * stream may skip entries on some filesystems. */
        char **names = NULL;
        size_t count = 0, cap = 0;
        struct dirent *ent;
        int failed = 0;
        errno = 0;
        while ((ent = readdir(d)) != NULL) {
            if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
            if (count == cap) {
                cap = cap ? cap * 2 : 32;
                char **grown = realloc(names, cap * sizeof(char *));
                if (!grown) die();
                names = grown;
            }
            names[count] = strdup(ent->d_name);
            if (!names[count]) die();
            count++;
        }
        closedir(d);
        int e = 0;
        for (size_t i = 0; i < count; i++) {
            if (!failed && remove_tree_at(fd, names[i], depth + 1) < 0 && errno != ENOENT) {
                failed = 1;
                e = errno;
            }
            free(names[i]);
        }
        free(names);
        close(fd);
        if (failed) {
            errno = e;
            return -1;
        }
        if (unlinkat(dir, name, AT_REMOVEDIR) == 0) return 0;
        if (errno != ENOTEMPTY && errno != EEXIST) return -1;
    }
    errno = ENOTEMPTY;
    return -1;
}

/* ------------------------------------------------------------------------ */
/* Operations                                                                */
/* ------------------------------------------------------------------------ */

static char walk_names[PATH_MAX / 2][MAX_NAME + 1];

static void op_open_root(struct in *in, struct out *o) {
    size_t len;
    const uint8_t *p = get_bin(in, &len);
    if (in->bad || len == 0 || len >= PATH_MAX || p[0] != '/' || memchr(p, 0, len)) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    char path[PATH_MAX];
    memcpy(path, p, len);
    path[len] = '\0';
    /* The root itself is trusted and may be reached through symlinks. */
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        reply_errno(o, errno);
        return;
    }
    int h = handle_put(fd);
    if (h < 0) {
        close(fd);
        reply_error(o, E_TOO_MANY);
        return;
    }
    reply_ok(o);
    put_u32(o, (uint32_t)h);
}

static void op_open_dir(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    uint32_t flags = get_u32(in);
    mode_t mode = (mode_t)(get_u32(in) & 07777);
    uint32_t count = get_u32(in);
    if (in->bad || count > sizeof(walk_names) / sizeof(walk_names[0])) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    for (uint32_t i = 0; i < count; i++) {
        if (get_name(in, walk_names[i], 0) < 0) {
            reply_error(o, E_BAD_REQUEST);
            return;
        }
    }
    if (in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    int fd = walk_dirs(dir, walk_names, count, (flags & DIR_CREATE) != 0, mode);
    if (fd < 0) {
        reply_errno(o, errno);
        return;
    }
    int h = handle_put(fd);
    if (h < 0) {
        close(fd);
        reply_error(o, E_TOO_MANY);
        return;
    }
    reply_ok(o);
    put_u32(o, (uint32_t)h);
}

static void op_close(struct in *in, struct out *o) {
    uint32_t h = get_u32(in);
    if (in->bad || handle_fd(h) < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    close(handles[h]);
    handles[h] = -1;
    reply_ok(o);
}

static void op_stat(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    if (get_name(in, name, 1) < 0 || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    struct stat st;
    int rc = name[0] ? fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) : fstat(dir, &st);
    if (rc < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
}

static void op_list(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    uint32_t max = get_u32(in);
    size_t prefix_len;
    const uint8_t *prefix = get_bin(in, &prefix_len);
    if (in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    int listfd = openat(dir, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    DIR *d = listfd >= 0 ? fdopendir(listfd) : NULL;
    if (!d) {
        int e = errno;
        if (listfd >= 0) close(listfd);
        reply_errno(o, e);
        return;
    }
    reply_ok(o);
    size_t count_at = o->len;
    put_u32(o, 0);
    uint32_t count = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        if (prefix_len && strncmp(ent->d_name, (const char *)prefix, prefix_len) != 0) continue;
        struct stat st;
        if (fstatat(dir, ent->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) continue;
        if (count == max) {
            closedir(d);
            reply_error(o, E_TOO_MANY);
            return;
        }
        put_bin(o, ent->d_name, strlen(ent->d_name));
        put_stat(o, &st);
        count++;
    }
    closedir(d);
    o->buf[count_at] = (uint8_t)(count >> 24);
    o->buf[count_at + 1] = (uint8_t)(count >> 16);
    o->buf[count_at + 2] = (uint8_t)(count >> 8);
    o->buf[count_at + 3] = (uint8_t)count;
}

static void op_read(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    uint64_t max = get_u64(in);
    uint32_t flags = get_u32(in);
    uint64_t dev = get_u64(in);
    uint64_t ino = get_u64(in);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    if (max > MAX_FRAME - 128) max = MAX_FRAME - 128;
    struct stat st;
    const char *err = NULL;
    int fd = open_regular(dir, name, O_RDONLY, &st, &err);
    if (fd < 0) {
        reply_error(o, err);
        return;
    }
    if (!expect_matches(&st, flags, dev, ino)) {
        close(fd);
        reply_error(o, E_CHANGED);
        return;
    }
    int prefix = (flags & FLAG_PREFIX) != 0;
    if (!prefix && (uint64_t)st.st_size > max) {
        close(fd);
        reply_error(o, E_TOO_LARGE);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
    size_t len_at = o->len;
    put_u32(o, 0);
    uint64_t total = 0;
    uint8_t chunk[65536];
    for (;;) {
        size_t want = sizeof(chunk);
        if (prefix) {
            if (total >= max) break;
            if (max - total < want) want = (size_t)(max - total);
        }
        ssize_t n = read(fd, chunk, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            close(fd);
            reply_errno(o, e);
            return;
        }
        if (n == 0) break;
        if (total + (uint64_t)n > max) {
            close(fd);
            reply_error(o, E_TOO_LARGE);
            return;
        }
        put_bytes_raw(o, chunk, (size_t)n);
        total += (uint64_t)n;
    }
    close(fd);
    o->buf[len_at] = (uint8_t)(total >> 24);
    o->buf[len_at + 1] = (uint8_t)(total >> 16);
    o->buf[len_at + 2] = (uint8_t)(total >> 8);
    o->buf[len_at + 3] = (uint8_t)total;
}

static void write_create(int dir, const char *name, mode_t mode, uint32_t flags,
                         const uint8_t *data, size_t len, struct out *o) {
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC, mode);
    if (fd < 0) {
        reply_errno(o, classify_open_error(dir, name, errno));
        return;
    }
    struct stat st;
    int rc = write_all(fd, data, len, 0);
    if (rc == 0 && (flags & FLAG_MODE_EXACT)) rc = fchmod(fd, mode);
    if (rc == 0 && (flags & FLAG_SYNC)) rc = full_sync(fd);
    if (rc == 0) rc = fstat(fd, &st);
    int e = errno;
    if (rc < 0) {
        struct stat mine, entry;
        if (fstat(fd, &mine) == 0 && fstatat(dir, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            same_object(&mine, &entry))
            unlinkat(dir, name, 0);
        close(fd);
        reply_errno(o, e);
        return;
    }
    close(fd);
    if ((flags & FLAG_SYNC) && full_sync(dir) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
}

/* Test-only interleaving point (argv `--test-stage-hook NOTIFY RESUME`, both
 * FIFOs): after a replacement's contents are written to its staging file and
 * before its mode is set or it is published, write the staging directory name
 * to NOTIFY and wait for one byte on RESUME. Never enabled in production. */
static const char *hook_notify;
static const char *hook_resume;

static void stage_hook(const char *stage) {
    if (!hook_notify) return;
    int fd = open(hook_notify, O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (write(fd, stage, strlen(stage)) < 0) {
            /* The test sees a short read and fails. */
        }
        close(fd);
    }
    fd = open(hook_resume, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        char byte;
        if (read(fd, &byte, 1) < 0) {
            /* Resume regardless. */
        }
        close(fd);
    }
}

/* A private staging directory `.lemon-stage-<random>` created in `dir` with
 * mode 0700 and held by descriptor. Replacement temporaries are created and
 * written inside it and published with renameat from the staging descriptor,
 * so the published source is never looked up by a name in `dir` that another
 * writer could substitute. */
static int make_staging(int dir, char name[64], struct stat *st) {
    for (int attempt = 0; attempt < 8; attempt++) {
        char suffix[32];
        if (random_suffix(suffix, sizeof(suffix)) < 0) {
            errno = EIO;
            return -1;
        }
        snprintf(name, 64, ".lemon-stage-%s", suffix);
        if (mkdirat(dir, name, 0700) < 0) {
            if (errno == EEXIST) continue;
            return -1;
        }
        int fd = open_dir_component(dir, name);
        if (fd < 0) return -1;
        if (fstat(fd, st) < 0 || !S_ISDIR(st->st_mode) || st->st_uid != geteuid() ||
            (st->st_mode & 077) != 0) {
            close(fd);
            errno = EBUSY;
            return -1;
        }
        return fd;
    }
    errno = EEXIST;
    return -1;
}

/* Remove the staging directory and anything left in it, only while its name
 * still refers to the directory we created. */
static void drop_staging(int dir, int sfd, const char *name, const struct stat *st) {
    unlinkat(sfd, "f", 0);
    close(sfd);
    struct stat now;
    if (fstatat(dir, name, &now, AT_SYMLINK_NOFOLLOW) == 0 && same_object(&now, st))
        unlinkat(dir, name, AT_REMOVEDIR);
}

/* Atomically publish `from` (in `sfd`) as `to` (in `dir`) only when `to` does
 * not exist. Filesystems without renameat2/renamex_np support fall back to
 * linkat, which is also an atomic no-replace publication. */
static int publish_noreplace(int sfd, const char *from, int dir, const char *to) {
    int rc;
#if defined(__APPLE__)
    rc = renameatx_np(sfd, from, dir, to, RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    rc = (int)syscall(SYS_renameat2, sfd, from, dir, to, RENAME_NOREPLACE);
#else
    errno = ENOSYS;
    rc = -1;
#endif
    if (rc == 0 || (errno != EINVAL && errno != ENOTSUP && errno != ENOSYS
#if defined(EOPNOTSUPP) && EOPNOTSUPP != ENOTSUP
                    && errno != EOPNOTSUPP
#endif
                    ))
        return rc;
    if (linkat(sfd, from, dir, to, 0) < 0) return -1;
    unlinkat(sfd, from, 0);
    return 0;
}

/* Final permission bits of a replacement: exact `mode`, the existing entry's
 * bits (setuid/setgid/sticky dropped), or `mode` under the umask. */
static mode_t replacement_mode(mode_t mode, uint32_t flags, int exists, const struct stat *existing) {
    if (flags & FLAG_MODE_EXACT) return mode;
    if ((flags & FLAG_PRESERVE_MODE) && exists) return existing->st_mode & 0777;
    return mode & ~process_umask & 0777;
}

static void write_replace(int dir, const char *name, mode_t mode, uint32_t flags, uint64_t dev,
                          uint64_t ino, const uint8_t *data, size_t len, struct out *o) {
    struct stat existing;
    int exists;
    const char *err = check_expectation(dir, name, flags, dev, ino, &existing, &exists);
    if (err) {
        reply_error(o, err);
        return;
    }
    char stage[64];
    struct stat stage_st;
    int sfd = make_staging(dir, stage, &stage_st);
    if (sfd < 0) {
        reply_errno(o, errno);
        return;
    }
    /* 0600 from the outset; the final mode is applied through the descriptor
     * before publication, so the contents are never more widely readable. */
    int fd = openat(sfd, "f", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC, 0600);
    if (fd < 0) {
        int e = errno;
        drop_staging(dir, sfd, stage, &stage_st);
        reply_errno(o, e);
        return;
    }
    struct stat st;
    int rc = write_all(fd, data, len, 0);
    if (rc == 0) stage_hook(stage);
    if (rc == 0) rc = fchmod(fd, replacement_mode(mode, flags, exists, &existing));
    if (rc == 0 && (flags & FLAG_SYNC)) rc = full_sync(fd);
    if (rc == 0) rc = fstat(fd, &st);
    int e = errno;
    close(fd);
    if (rc < 0) {
        drop_staging(dir, sfd, stage, &stage_st);
        reply_errno(o, e);
        return;
    }
    struct stat staged;
    if (fstatat(sfd, "f", &staged, AT_SYMLINK_NOFOLLOW) < 0 || !same_object(&staged, &st)) {
        drop_staging(dir, sfd, stage, &stage_st);
        reply_error(o, E_CHANGED);
        return;
    }
    if (flags & FLAG_EXPECT_ABSENT) {
        rc = publish_noreplace(sfd, "f", dir, name);
    } else {
        /* Best-effort conflict detection, not compare-and-swap: an entry
         * replaced between this check and the rename is overwritten. */
        struct stat again;
        int exists_again;
        err = check_expectation(dir, name, flags, dev, ino, &again, &exists_again);
        if (err) {
            drop_staging(dir, sfd, stage, &stage_st);
            reply_error(o, err);
            return;
        }
        rc = renameat(sfd, "f", dir, name);
    }
    e = errno;
    drop_staging(dir, sfd, stage, &stage_st);
    if (rc < 0) {
        reply_errno(o, e);
        return;
    }
    /* The published entry must be the file written here (detects a
     * same-user substitution inside the staging directory). */
    struct stat published;
    if (fstatat(dir, name, &published, AT_SYMLINK_NOFOLLOW) < 0 || !same_object(&published, &st)) {
        reply_error(o, E_CHANGED);
        return;
    }
    if ((flags & FLAG_SYNC) && full_sync(dir) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
}

/* Append `data` to the regular file `name` (no-follow, O_APPEND), creating it
 * exclusively with `mode` when absent and FLAG_CREATE is set. */
static void op_append(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    mode_t mode = (mode_t)(get_u32(in) & 07777);
    uint32_t flags = get_u32(in);
    uint64_t dev = get_u64(in);
    uint64_t ino = get_u64(in);
    size_t len;
    const uint8_t *data = get_bin(in, &len);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    struct stat st;
    const char *err = NULL;
    int fd = -1;
    if ((flags & FLAG_CREATE) && !(flags & FLAG_EXPECT_IDENTITY)) {
        fd = openat(dir, name,
                    O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC, mode);
        if (fd >= 0 && fstat(fd, &st) < 0) {
            int e = errno;
            close(fd);
            reply_errno(o, e);
            return;
        }
        if (fd < 0 && errno != EEXIST) {
            reply_errno(o, classify_open_error(dir, name, errno));
            return;
        }
    }
    if (fd < 0) {
        fd = open_regular(dir, name, O_WRONLY | O_APPEND, &st, &err);
        if (fd < 0) {
            reply_error(o, err);
            return;
        }
    }
    if (!expect_matches(&st, flags, dev, ino)) {
        close(fd);
        reply_error(o, E_CHANGED);
        return;
    }
    int rc = (flags & FLAG_MODE_EXACT) ? fchmod(fd, mode) : 0;
    const uint8_t *p = data;
    size_t left = len;
    while (rc == 0 && left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            rc = -1;
            break;
        }
        p += n;
        left -= (size_t)n;
    }
    if (rc == 0 && (flags & FLAG_SYNC)) rc = full_sync(fd);
    if (rc == 0) rc = fstat(fd, &st);
    int e = errno;
    close(fd);
    if (rc < 0) {
        reply_errno(o, e);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
}

static void write_overwrite(int dir, const char *name, uint32_t flags, uint64_t dev, uint64_t ino,
                            const uint8_t *data, size_t len, struct out *o) {
    struct stat st;
    const char *err = NULL;
    int fd = open_regular(dir, name, O_WRONLY, &st, &err);
    if (fd < 0) {
        reply_error(o, err);
        return;
    }
    if (!expect_matches(&st, flags, dev, ino)) {
        close(fd);
        reply_error(o, E_CHANGED);
        return;
    }
    int rc = write_all(fd, data, len, 0);
    if (rc == 0) rc = ftruncate(fd, (off_t)len);
    if (rc == 0 && (flags & FLAG_SYNC)) rc = full_sync(fd);
    if (rc == 0) rc = fstat(fd, &st);
    int e = errno;
    close(fd);
    if (rc < 0) {
        reply_errno(o, e);
        return;
    }
    reply_ok(o);
    put_stat(o, &st);
}

static void op_write(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    uint32_t how = get_u32(in);
    mode_t mode = (mode_t)(get_u32(in) & 07777);
    uint32_t flags = get_u32(in);
    uint64_t dev = get_u64(in);
    uint64_t ino = get_u64(in);
    size_t len;
    const uint8_t *data = get_bin(in, &len);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    switch (how) {
    case HOW_CREATE: write_create(dir, name, mode, flags, data, len, o); break;
    case HOW_REPLACE: write_replace(dir, name, mode, flags, dev, ino, data, len, o); break;
    case HOW_OVERWRITE: write_overwrite(dir, name, flags, dev, ino, data, len, o); break;
    default: reply_error(o, E_BAD_REQUEST); break;
    }
}

static void op_mkdir(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    mode_t mode = (mode_t)(get_u32(in) & 07777);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    if (mkdirat(dir, name, mode) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_unlink(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    uint32_t flags = get_u32(in);
    uint64_t dev = get_u64(in);
    uint64_t ino = get_u64(in);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    struct stat st;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
        reply_errno(o, errno);
        return;
    }
    if (S_ISDIR(st.st_mode)) {
        reply_error(o, "eisdir");
        return;
    }
    if (!expect_matches(&st, flags, dev, ino)) {
        reply_error(o, E_CHANGED);
        return;
    }
    if (unlinkat(dir, name, 0) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_rmdir(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    if (get_name(in, name, 0) < 0 || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    if (unlinkat(dir, name, AT_REMOVEDIR) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_remove_tree(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    if (get_name(in, name, 0) < 0 || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    if (remove_tree_at(dir, name, 0) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_rename(struct in *in, struct out *o) {
    int from_dir = handle_fd(get_u32(in));
    char from[MAX_NAME + 1];
    int bad1 = get_name(in, from, 0);
    int to_dir = handle_fd(get_u32(in));
    char to[MAX_NAME + 1];
    int bad2 = get_name(in, to, 0);
    uint32_t flags = get_u32(in);
    if (bad1 < 0 || bad2 < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (from_dir < 0 || to_dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    int rc;
    if (flags & RENAME_FLAG_NOREPLACE) {
        /* Atomic no-replace; on filesystems without renameat2/renamex_np
         * support a non-directory falls back to linkat (still no-replace). */
        rc = publish_noreplace(from_dir, from, to_dir, to);
    } else {
        rc = renameat(from_dir, from, to_dir, to);
    }
    if (rc < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_chmod(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 1);
    mode_t mode = (mode_t)(get_u32(in) & 07777);
    if (bad < 0 || in->bad || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    int rc = name[0] ? chmod_at(dir, name, mode) : fchmod(dir, mode);
    if (rc < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_symlink(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    int bad = get_name(in, name, 0);
    size_t len;
    const uint8_t *target = get_bin(in, &len);
    if (bad < 0 || in->bad || in->n != 0 || len == 0 || len >= PATH_MAX || memchr(target, 0, len)) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    char buf[PATH_MAX];
    memcpy(buf, target, len);
    buf[len] = '\0';
    if (symlinkat(buf, dir, name) < 0) {
        reply_errno(o, errno);
        return;
    }
    reply_ok(o);
}

static void op_readlink(struct in *in, struct out *o) {
    int dir = handle_fd(get_u32(in));
    char name[MAX_NAME + 1];
    if (get_name(in, name, 0) < 0 || in->n != 0) {
        reply_error(o, E_BAD_REQUEST);
        return;
    }
    if (dir < 0) {
        reply_error(o, E_BAD_HANDLE);
        return;
    }
    char buf[PATH_MAX];
    ssize_t n = readlinkat(dir, name, buf, sizeof(buf));
    if (n < 0) {
        reply_errno(o, errno);
        return;
    }
    if ((size_t)n >= sizeof(buf)) {
        reply_error(o, "enametoolong");
        return;
    }
    reply_ok(o);
    put_bin(o, buf, (size_t)n);
}

/* ------------------------------------------------------------------------ */
/* Port loop                                                                 */
/* ------------------------------------------------------------------------ */

static int read_exact(uint8_t *buf, size_t len) {
    while (len > 0) {
        ssize_t n = read(STDIN_FILENO, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static void write_exact(const uint8_t *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(STDOUT_FILENO, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            _exit(0);
        }
        buf += n;
        len -= (size_t)n;
    }
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    process_umask = umask(077);
    umask(process_umask);
    if (argc == 4 && strcmp(argv[1], "--test-stage-hook") == 0) {
        hook_notify = argv[2];
        hook_resume = argv[3];
    } else if (argc != 1) {
        return 64;
    }
    for (int i = 0; i <= MAX_HANDLES; i++) handles[i] = -1;
    struct out o = {0};
    uint8_t *req = NULL;
    size_t req_cap = 0;
    for (;;) {
        uint8_t hdr[4];
        if (read_exact(hdr, 4) < 0) return 0;
        uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                       ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
        if (len == 0 || len > MAX_FRAME) return 64;
        if (len > req_cap) {
            uint8_t *grown = realloc(req, len);
            if (!grown) return 70;
            req = grown;
            req_cap = len;
        }
        if (read_exact(req, len) < 0) return 0;
        struct in in = {req + 1, len - 1, 0};
        o.len = 0;
        switch (req[0]) {
        case OP_OPEN_ROOT: op_open_root(&in, &o); break;
        case OP_OPEN_DIR: op_open_dir(&in, &o); break;
        case OP_CLOSE: op_close(&in, &o); break;
        case OP_STAT: op_stat(&in, &o); break;
        case OP_LIST: op_list(&in, &o); break;
        case OP_READ: op_read(&in, &o); break;
        case OP_WRITE: op_write(&in, &o); break;
        case OP_MKDIR: op_mkdir(&in, &o); break;
        case OP_UNLINK: op_unlink(&in, &o); break;
        case OP_RMDIR: op_rmdir(&in, &o); break;
        case OP_REMOVE_TREE: op_remove_tree(&in, &o); break;
        case OP_RENAME: op_rename(&in, &o); break;
        case OP_CHMOD: op_chmod(&in, &o); break;
        case OP_SYMLINK: op_symlink(&in, &o); break;
        case OP_READLINK: op_readlink(&in, &o); break;
        case OP_APPEND: op_append(&in, &o); break;
        default: reply_error(&o, E_BAD_REQUEST); break;
        }
        uint8_t out_hdr[4] = {(uint8_t)(o.len >> 24), (uint8_t)(o.len >> 16),
                              (uint8_t)(o.len >> 8), (uint8_t)o.len};
        write_exact(out_hdr, 4);
        write_exact(o.buf, o.len);
        /* Release large buffers between requests. */
        if (o.cap > (1u << 20)) {
            free(o.buf);
            o.buf = NULL;
            o.cap = 0;
        }
        if (req_cap > (1u << 20)) {
            free(req);
            req = NULL;
            req_cap = 0;
        }
    }
}
