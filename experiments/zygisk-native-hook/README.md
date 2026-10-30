# 实验：Zygisk native hook（针对抖音的 BoringSSL pinning）

> ⚠️ **这是失败实验的存档，不要直接刷到主力机上。**
> 它能让抖音的「固定证书」报错消失，但抖音会在 `libsscronet.so` 里主动 `BRK` 崩溃（进入安全模式 → 断网 + 闪退）。
> 保留这份代码的价值在于：它演示了「Zygisk 注入 + 手写 ELF PLT/GOT 劫持 + 命中后还原」这一套做法，可复用到别的目标上。

## 它做什么

Zygisk 注入到 `com.ss.android.ugc.aweme` 进程后：

1. 遍历 `dl_iterate_phdr` 拿到已加载的 so；
2. 解析 `.dynamic` / `.dynsym` / `.dynstr` / `.rela.plt`，找到对下列符号的 `R_AARCH64_JUMP_SLOT` 重定位，把 GOT 槽改写成自己的函数：
   - `SSL_CTX_set_custom_verify` → 换成"永远返回 `ssl_verify_ok`"的回调，等于把校验回调打进 `SSL_CTX`
   - `X509_VERIFY_PARAM_set1_host` → 直接返回 1，跳过主机名校验
3. 一旦发现 hook 被调用过（说明 `SSL_CTX` 已经建好、回调已存进去），**立刻把 GOT 还原**，让完整性自检看到干净的 GOT；
4. 只处理目标 App 自己目录下的 so，系统库不碰。

## 为什么失败

抖音的 native 层有主动反中间人：即使 GOT 已还原、只剩"证书链与预期不符"这一事实，它仍然在 `libsscronet.so+0x2c8e24` 执行 `BRK`：

```
signal 5 (SIGTRAP), code 1 (TRAP_BRKPT)
#00 pc 00000000002c8e24  .../lib/arm64/libsscronet.so
```

详见 [docs/微信抓包证书问题_排查与解决.md](../../docs/微信抓包证书问题_排查与解决.md) 第九节。

## 目录

```
jni/module.cpp        模块实现（Zygisk API v5 + 手写 GOT patch）
jni/zygisk.hpp        Zygisk 公共 API 头文件（来自 topjohnwu/zygisk-module-sample，MIT）
build.ps1             NDK 编译脚本（NDK r26+，aarch64）
module.prop           模块元信息
```

## 编译

```powershell
.\build.ps1              # 产物 zygisk/arm64-v8a.so
```

模块安装布局（KernelSU / Magisk + Zygisk Next）：

```
/data/adb/modules/<id>/
├── module.prop
└── zygisk/arm64-v8a.so
```

## 踩坑记录

| 坑 | 说明 |
|---|---|
| `mprotect(RWX)` 失败 | Android SELinux(execmem) 不允许把文件映射改成 RWX，只能 `RW → 写 → RX` |
| `mprotect` 不能只给 W | 若写完不恢复 `PROT_EXEC`，同页其它 GOT 项被调用会 SIGSEGV |
| 系统库别碰 | 早期版本连 `libssl.so`/`libcurl.so` 一起 hook，检测面变大 |
| 检测点不一定在 GOT | 抖音检测的是"证书不符合 pin"，还原 GOT 也没用 |
