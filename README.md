# android-system-ca-capture

Android 14+（含 Android 15/16/17）把抓包工具的根证书装进**系统**信任库的 KernelSU / Magisk 模块，
并附一篇关于「Xposed 证书模块导致新版微信网页打不开」的完整排查记录。

> 关键词：Android APEX conscrypt、`/apex/com.android.conscrypt/cacerts`、mount namespace、
> TrustMeAlready、`TrustManagerImpl.checkTrustedRecursive`、微信 XWeb / Chromium `X509Util`、HttpCanary

---

## 解决的两个问题

**问题一：Xposed 证书模块让新版微信打不开网页**

把 TrustMeAlready 之类模块的作用域勾到微信后，微信内打开任何网页都提示「该网站的安全证书存在问题」。
原因是这类模块把 `TrustManagerImpl.checkTrustedRecursive()` 的返回值替换成**空链表**：

- Java/OkHttp 客户端只关心"有没有抛异常"，所以看起来"绕过成功"；
- 但新版微信网页内核是 XWeb（Chromium），`X509Util` 会用返回链的**最后一个证书**去比对系统根，
  空链 → `isIssuedByKnownRoot = false` → 判为不可信 → 弹安全警告。

旧版微信用 X5/TBS（native 校验）所以当时没事，换 XWeb 后必然翻车。
详细证据链见 [docs/微信抓包证书问题_排查与解决.md](docs/微信抓包证书问题_排查与解决.md)。

**问题二：Android 14+ 系统证书装不进去**

- 系统证书库已迁移到只读 APEX：`/apex/com.android.conscrypt/cacerts`；
- 每个应用进程有**独立 mount namespace**，运行期 `mount --bind` 不会传播到应用；
- 应用默认只信任**系统**锚点（`trust-anchors=system`），用户证书对 WeChat / WebView 一律无效。

本模块在 `post-fs-data`（zygote 启动前）把「系统证书 + 你的证书」合并后 bind mount 到两个证书库路径，
所有应用进程启动时自然继承；`service.sh` 在 late_start 再兜底一次，并对已运行的应用进程用 `nsenter` 补挂。

---

## 下载

见 [Releases](https://github.com/Sukidao/android-system-ca-capture/releases)：

| 文件 | 说明 |
|---|---|
| `hc_cacert.zip` | 模块包（KernelSU / Magisk），已内置一张 HttpCanary 根证书，可直接刷 |
| `HttpCanary-3.3.6.apk` | 抓包工具安装包；**第三方软件**，版权归原作者所有，此处仅作存档，如有侵权请联系删除 |

## 快速开始

```sh
# 1. 换成你自己的根证书（可放多张）
openssl x509 -in your_ca.pem -noout -subject_hash_old      # 得到 <hash>
cp your_ca.pem module/certs/<hash>.0

# 2. 打包
python tools/build_zip.py                                  # 输出 hc_cacert.zip

# 3. 刷入并重启
#    KernelSU / Magisk 管理器 -> 模块 -> 从本地安装 -> 选择 hc_cacert.zip -> 重启
```

仓库自带一张 HttpCanary 根证书（`module/certs/87bc3517.0`）作为示例；只有公钥证书，无私钥，替换成你自己的即可。

### 验证

```sh
# 两个证书库都应是「原数量 + 你的证书数量」（常见系统为 145 + N）
su -c 'ls /apex/com.android.conscrypt/cacerts | wc -l'
su -c 'ls /system/etc/security/cacerts | wc -l'

# 开机日志
su -c 'cat /data/local/tmp/hc_cacert.log'
# === post-fs-data ===
# src=/apex/com.android.conscrypt/cacerts base=145 certs=1 new=146
# mounted /apex/com.android.conscrypt/cacerts -> 146
# mounted /system/etc/security/cacerts -> 146
```

抓包工具开抓后，目标 App 的 HTTPS 应能直接出明文。

---

## 目录结构

```
module/
├── module.prop                     # 模块元信息
├── post-fs-data.sh                 # 开机早期合并证书 + bind mount（带数量校验，失败不挂载）
├── service.sh                      # late_start 兜底 + 对已运行进程 nsenter 补挂
├── certs/                          # 你的根证书：<subject_hash_old>.0（PEM）
└── META-INF/com/google/android/    # 安装脚本（Magisk 走官方 install_module，无 Magisk 环境自动解包回退）
docs/
└── 微信抓包证书问题_排查与解决.md      # 完整排查/原理/验证记录
tools/
└── build_zip.py                    # 打包脚本
```

---

## 设计要点 / 踩坑记录

| 点 | 说明 |
|---|---|
| 文件名 | 必须是 `subject_hash_old`（MD5 旧式）结果 + `.0`，不是 `subject_hash` |
| SELinux | 合并目录需 `chcon -R u:object_r:system_file:s0`，否则应用读不到 |
| mount 时机 | 必须 `post-fs-data`（zygote 之前）；运行期挂载在应用 namespace 内不可见 |
| 两处路径 | `conscrypt` 读 `/apex/.../cacerts`；Chromium 的 `isKnownRoot` 还会看 `/system/.../cacerts`，两处都挂更稳 |
| 失败保护 | 脚本会校验「合并后数量 = 原数量 + 证书数」，不满足就不挂载，避免把整机 TLS 搞坏 |
| `nsenter` | 设备上多为 toybox 版，`mount` 前必须加 `--`，否则报 `Unknown option 'bind'` |
| 不要混用 | 证书模块与「返回空链」的 Xposed 模块不要同时作用于同一 App，尤其浏览器/微信 |

### 抓不到的部分

微信自有通信是 MMTLS / mars native 栈（大量 `http://xxx.weixin.qq.com/mmtls/...`），属于应用层加密，
装了系统证书也只能看到封装层；能解的是内嵌网页、小程序资源、以及走标准 TLS 的第三方域名。

---

## 免责声明

本项目仅用于**自有设备、自有应用或已获授权**的安全测试与调试。
用它绕过第三方应用的证书校验可能违反其服务条款或当地法律法规，由使用者自行承担全部责任。

## License

MIT
