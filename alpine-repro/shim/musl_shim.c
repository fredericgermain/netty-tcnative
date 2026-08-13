/*
 * Feasibility probe only -- NOT a proposed fix.
 *
 * Supplies the glibc-internal symbols that Netty's prebuilt natives import but musl does
 * not export. This mirrors what async-profiler does with its weak __sprintf_chk shim
 * (https://github.com/async-profiler/async-profiler/issues/952); the difference is that
 * they compile the shim into libasyncProfiler.so, whereas here we LD_PRELOAD it so we can
 * measure the released artifacts without rebuilding them.
 *
 * Build:  gcc -shared -fPIC -o musl_shim.so musl_shim.c
 * Use:    LD_PRELOAD=./musl_shim.so java ...
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <sys/auxv.h>

/* epoll: netty compiles netty_unix_errors.c against the XSI strerror_r, which glibc
 * exposes under this internal name. musl only has the XSI form, unprefixed. */
int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    return strerror_r(errnum, buf, buflen);
}

/* tcnative/BoringSSL CPU feature detection. glibc exports both getauxval and the
 * __-prefixed alias; musl exports only getauxval (and gcompat supplies __getauxval,
 * which is why tcnative 2.0.65 worked when libcrypt.so.1 dragged gcompat in). */
unsigned long __getauxval(unsigned long type) {
    return getauxval(type);
}

/* APR/BoringSSL were built with _LARGEFILE64_SOURCE against old glibc. musl 1.2.4
 * (Alpine 3.19+) removed the LFS64 aliases entirely -- off_t is already 64-bit. */
FILE *fopen64(const char *path, const char *mode) {
    return fopen(path, mode);
}

/* glibc-internal math aliases emitted by APR's configure-era headers. */
int __isinf(double x) { return isinf(x); }
int __isnan(double x) { return isnan(x); }

/* glibc-internal aliases APR links against directly. */
char *__strdup(const char *s) { return strdup(s); }

int __pthread_key_create(pthread_key_t *key, void (*destructor)(void *)) {
    return pthread_key_create(key, destructor);
}
