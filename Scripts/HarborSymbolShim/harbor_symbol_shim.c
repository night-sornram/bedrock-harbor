/*
 * Harbor symbol shim — guest mod providing bionic libc symbols that the macOS
 * bionic libc shim does not export, for Bedrock builds the official
 * mcpelauncher-updates mod cannot handle (1.26.50+ crash in its pairip VM).
 *
 * Mechanism (same as mcpelauncher-updates' add_symbols, see its public
 * src/main.cpp): at mod_preinit, resolve libmcpelauncher_mod.so!mcpelauncher_relocate
 * and inject our implementations into the already-loaded guest libc.so so they
 * satisfy libminecraftpe.so's dynamic lookups. Plain exports are NOT enough —
 * the guest linker does not add mod-local symbols to the resolution scope.
 *
 * All implementations are freestanding (no libc imports). dlopen/dlsym come
 * from the guest's internal libdl provider via DT_NEEDED (as in the official mod).
 *
 * Build (macOS host, ELF guest):
 *   clang --target=aarch64-linux-elf -march=armv8-a -c -O2 -fPIC \
 *       -ffreestanding -fno-builtin -o harbor_symbol_shim.o harbor_symbol_shim.c
 *   rust-lld -flavor gnu -shared -nostdlib \
 *       --no-as-needed -soname libharbor_symbol_shim.so \
 *       -o libharbor_symbol_shim.so harbor_symbol_shim.o stub_libdl.so
 *
 * Install: BedrockHarbor/Patches/<gameVersion>/arm64-v8a/libharbor_symbol_shim.so
 * (Harbor passes that directory via mcpelauncher-client `-m`.)
 */

typedef unsigned long harbor_size_t;
typedef long harbor_ssize_t;

/* Guest imports: the linker's internal libdl provider (see DT_NEEDED libdl.so). */
extern void *dlopen(const char *filename, int flags);
extern void *dlsym(void *handle, const char *symbol);

/* Bionic RTLD_NOLOAD (the guest linker uses Android values). */
#define HARBOR_RTLD_NOLOAD 4

typedef void (*harbor_relocate_fn)(void *handle, const char *name, void *hook);

typedef struct { long quot; long rem; } harbor_ldiv_t;
typedef struct { long long quot; long long rem; } harbor_lldiv_t;
typedef struct { int quot; int rem; } harbor_div_t;

__attribute__((visibility("default")))
harbor_ldiv_t ldiv(long numer, long denom) {
    harbor_ldiv_t r;
    r.quot = numer / denom;
    r.rem = numer % denom;
    return r;
}

__attribute__((visibility("default")))
harbor_lldiv_t lldiv(long long numer, long long denom) {
    harbor_lldiv_t r;
    r.quot = numer / denom;
    r.rem = numer % denom;
    return r;
}

__attribute__((visibility("default")))
harbor_div_t div(int numer, int denom) {
    harbor_div_t r;
    r.quot = numer / denom;
    r.rem = numer % denom;
    return r;
}

/* fortify wrappers referenced by newer NDK toolchains; bounds are enforced by callers. */
__attribute__((visibility("default")))
harbor_size_t __strlcpy_chk(char *dst, const char *src, harbor_size_t n, harbor_size_t dstlen) {
    harbor_size_t i = 0;
    if (n != 0) {
        while (i + 1 < n && src[i] != '\0') { dst[i] = src[i]; i++; }
        dst[i] = '\0';
        while (src[i] != '\0') i++;
    }
    return i;
}

static void *harbor_memcpy_impl(void *dst, const void *src, harbor_size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (harbor_size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

static void *harbor_memset_impl(void *dst, int c, harbor_size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (harbor_size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

__attribute__((visibility("default")))
void *__memcpy_chk(void *dst, const void *src, harbor_size_t n, harbor_size_t dstlen) {
    return harbor_memcpy_impl(dst, src, n);
}

__attribute__((visibility("default")))
void *__memset_chk(void *dst, int c, harbor_size_t n, harbor_size_t dstlen) {
    return harbor_memset_impl(dst, c, n);
}

__attribute__((visibility("default")))
void mod_preinit(void) {
    void *mcpelauncher_mod = dlopen("libmcpelauncher_mod.so", HARBOR_RTLD_NOLOAD);
    if (mcpelauncher_mod == 0)
        return;
    harbor_relocate_fn relocate = (harbor_relocate_fn)dlsym(mcpelauncher_mod, "mcpelauncher_relocate");
    if (relocate == 0)
        return;
    void *libc = dlopen("libc.so", HARBOR_RTLD_NOLOAD);
    if (libc == 0)
        return;
    relocate(libc, "ldiv", (void *)&ldiv);
    relocate(libc, "lldiv", (void *)&lldiv);
    relocate(libc, "div", (void *)&div);
    relocate(libc, "__strlcpy_chk", (void *)&__strlcpy_chk);
    relocate(libc, "__memcpy_chk", (void *)&__memcpy_chk);
    relocate(libc, "__memset_chk", (void *)&__memset_chk);
}

/* ModLoader logs a warning when mod_init is absent; provide an empty one. */
__attribute__((visibility("default")))
void mod_init(void) {
}
