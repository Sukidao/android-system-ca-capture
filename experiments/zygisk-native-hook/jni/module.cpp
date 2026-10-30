// pinskip: 通过 Zygisk 注入目标 App 进程，劫持其对 BoringSSL 的 PLT 调用，
// 关掉 native 层的证书校验（pinning）与主机名校验，使 HTTPS 可被中间人解密。
// 仅对 TARGET_PKG 生效，其它进程不做任何事。

#include <jni.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/mman.h>
#include <link.h>
#include <elf.h>
#include <android/log.h>

#include "zygisk.hpp"

#define TAG "pinskip"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static const char *TARGET_PKG = "com.ss.android.ugc.aweme";

// ---------- BoringSSL 函数签名 ----------
typedef int (*custom_verify_cb_t)(void *ssl, uint8_t *out_alert);
typedef int (*set_custom_verify_t)(void *ctx, int mode, custom_verify_cb_t cb);
typedef int (*verify_cb_t)(int preverify_ok, void *x509_ctx);
typedef int (*set_verify_t)(void *ctx, int mode, verify_cb_t cb);
typedef int (*set1_host_t)(void *param, const char *hostname, size_t len);
typedef int (*set1_ip_t)(void *param, const char *ip);
typedef int (*get_verify_result_t)(void *ssl);

static set_custom_verify_t real_set_custom_verify = nullptr;
static set_verify_t real_set_verify = nullptr;

// ssl_verify_ok == 0
static int bypass_cb(void *ssl, uint8_t *alert) {
    (void) ssl;
    if (alert) *alert = 0;
    return 0;
}

static volatile int g_hit = 0;   // 我们的 hook 被调用过几次（= SSL_CTX 已建立）

static int my_set_custom_verify(void *ctx, int mode, custom_verify_cb_t cb) {
    (void) cb;
    g_hit++;
    if (!real_set_custom_verify) return 1;
    // 把 App 自己的校验回调换成"永远通过"，这个回调会被存进 SSL_CTX，
    // 即使随后把 GOT 还原，后续握手仍然走我们的回调。
    return real_set_custom_verify(ctx, mode, bypass_cb);
}

static int my_set1_host(void *param, const char *hostname, size_t len) {
    (void) param;
    (void) hostname;
    (void) len;
    return 1;
}

struct Target {
    const char *name;
    void *fn;
    void **orig;
};

static Target g_targets[] = {
    {"SSL_CTX_set_custom_verify",       (void *) my_set_custom_verify,  (void **) &real_set_custom_verify},
    {"X509_VERIFY_PARAM_set1_host",     (void *) my_set1_host,          nullptr},
};

// ---------- 工具 ----------
static uintptr_t dyn_fixup(struct dl_phdr_info *info, ElfW(Addr) ptr) {
    // Android 的 .dynamic 里大多已是绝对地址，个别是 vaddr，做一次保守修正
    if (ptr < (ElfW(Addr)) info->dlpi_addr) return ptr + info->dlpi_addr;
    return ptr;
}

static void *page_start(void *p) {
    return (void *) ((uintptr_t) p & ~(uintptr_t) (getpagesize() - 1));
}

// 注意：Android 的 SELinux(execmem) 不允许把文件映射改成 RWX，
// 只能 RW -> 写 -> RX；窗口极短（微秒级），且只写一个 8 字节指针。
static bool make_writable(void *addr, size_t len) {
    void *start = page_start(addr);
    uintptr_t end = ((uintptr_t) addr + len + getpagesize() - 1) & ~(uintptr_t) (getpagesize() - 1);
    return mprotect(start, (size_t) ((uintptr_t) end - (uintptr_t) start),
                    PROT_READ | PROT_WRITE) == 0;
}

static void make_executable(void *addr, size_t len) {
    void *start = page_start(addr);
    uintptr_t end = ((uintptr_t) addr + len + getpagesize() - 1) & ~(uintptr_t) (getpagesize() - 1);
    mprotect(start, (size_t) ((uintptr_t) end - (uintptr_t) start), PROT_READ | PROT_EXEC);
}

static int patched_slots = 0;

// 记录被改写过的 GOT 槽，命中后要还原，让完整性自检看到"干净"的 GOT
static void **g_slots[32];
static void *g_origs[32];
static int g_nslots = 0;

static void restore_slots() {
    for (int i = 0; i < g_nslots; i++) {
        if (make_writable(g_slots[i], sizeof(void *))) {
            __atomic_store_n(g_slots[i], g_origs[i], __ATOMIC_SEQ_CST);
            make_executable(g_slots[i], sizeof(void *));
        }
    }
    if (g_nslots > 0) LOGI("restored %d got slot(s)", g_nslots);
    g_nslots = 0;
}

static int patch_lib(struct dl_phdr_info *info, size_t, void *) {
    if (!info->dlpi_name || info->dlpi_name[0] == '\0') return 0;
    // 只碰目标 App 自己目录下的 so，系统库一律不碰（减少被检测面）
    if (!strstr(info->dlpi_name, "com.ss.android.ugc.aweme")) return 0;

    const ElfW(Dyn) *dyn = nullptr;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
            dyn = (const ElfW(Dyn) *) (info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
            break;
        }
    }
    if (!dyn) return 0;

    const ElfW(Sym) *symtab = nullptr;
    const char *strtab = nullptr;
    const ElfW(Rela) *jmprel = nullptr;
    size_t pltrelsz = 0;
    int pltrel = 0;

    for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
            case DT_SYMTAB:     symtab = (const ElfW(Sym) *) dyn_fixup(info, d->d_un.d_ptr); break;
            case DT_STRTAB:     strtab = (const char *) dyn_fixup(info, d->d_un.d_ptr); break;
            case DT_JMPREL:     jmprel = (const ElfW(Rela) *) dyn_fixup(info, d->d_un.d_ptr); break;
            case DT_PLTRELSZ:   pltrelsz = d->d_un.d_val; break;
            case DT_PLTREL:     pltrel = (int) d->d_un.d_val; break;
            default: break;
        }
    }
    if (!symtab || !strtab || !jmprel || pltrel != DT_RELA || pltrelsz == 0) return 0;

    size_t n = pltrelsz / sizeof(ElfW(Rela));
    for (size_t i = 0; i < n; i++) {
        const ElfW(Rela) &r = jmprel[i];
        if (ELF64_R_TYPE(r.r_info) != R_AARCH64_JUMP_SLOT) continue;
        size_t idx = ELF64_R_SYM(r.r_info);
        const char *nm = strtab + symtab[idx].st_name;
        if (!nm || !nm[0]) continue;

        for (auto &t : g_targets) {
            if (strcmp(nm, t.name) != 0) continue;
            void **slot = (void **) (info->dlpi_addr + r.r_offset);
            if (*slot == t.fn) break;
            void *orig = *slot;
            if (t.orig && *t.orig == nullptr && orig != nullptr) *t.orig = orig;
            if (make_writable(slot, sizeof(void *))) {
                __atomic_store_n(slot, t.fn, __ATOMIC_SEQ_CST);
                make_executable(slot, sizeof(void *));
                if (g_nslots < 32) {
                    g_slots[g_nslots] = slot;
                    g_origs[g_nslots] = orig;
                    g_nslots++;
                }
                patched_slots++;
                LOGI("hook %s in %s (slot=%p orig=%p)", nm, info->dlpi_name, (void *) slot, orig);
            } else {
                LOGE("mprotect failed for %s in %s", nm, info->dlpi_name);
            }
            break;
        }
    }
    return 0;
}

static void *watcher(void *) {
    // 策略：尽早挂上（必须在 App 创建 SSL_CTX 之前），
    // 一旦确认 hook 被调用过（校验回调已被替换进 SSL_CTX），
    // 立刻把 GOT 还原，避免被 native 完整性自检扫到（否则 libsscronet 会 brk 自杀）。
    for (int i = 0; i < 100; i++) {
        dl_iterate_phdr(patch_lib, nullptr);
        if (g_hit > 0) {
            LOGI("hook hit=%d, restoring got", g_hit);
            restore_slots();
            return nullptr;
        }
        usleep(100 * 1000); // 最多等 10s
    }
    LOGI("no hit in 10s, restoring got anyway (restored to be safe)");
    restore_slots();
    return nullptr;
}

class PinSkip : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        if (!args->nice_name) return;
        const char *name = env->GetStringUTFChars(args->nice_name, nullptr);
        if (name) {
            is_target = strncmp(name, TARGET_PKG, strlen(TARGET_PKG)) == 0;
            env->ReleaseStringUTFChars(args->nice_name, name);
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!is_target) return;
        pthread_t th;
        if (pthread_create(&th, nullptr, watcher, nullptr) == 0) {
            pthread_detach(th);
            LOGI("pinskip armed, pid=%d", getpid());
        } else {
            LOGE("pthread_create failed");
        }
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    bool is_target = false;
};

REGISTER_ZYGISK_MODULE(PinSkip)
