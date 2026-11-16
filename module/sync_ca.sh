#!/system/bin/sh
# sync_ca.sh —— 让系统证书库里的 HttpCanary 根证书与 HttpCanary 当前使用的保持一致
# 场景：HttpCanary 重置/清数据后重新生成 CA（CN 不变 → 文件名哈希不变，仅内容变），
#       旧逻辑只会在开机时拷贝 certs/ 里的旧证书，导致抓包全挂。
# 做法：比对 → 覆盖 bind 挂载源（对已挂载命名空间立即生效）→ 同步回模块 certs/

MODDIR=${0%/*}
WORK=/data/local/tmp/hc_cacerts
LOG=/data/local/tmp/hc_cacert.log
CERTS=$MODDIR/certs
CANARY_CA=/data/data/com.guoshi.httpcanary/files/backup/HttpCanary.pem
APEX=/apex/com.android.conscrypt/cacerts
SYS=/system/etc/security/cacerts

log() { echo "$(date '+%m-%d %H:%M:%S') sync: $*" >> "$LOG"; }

if [ ! -f "$CANARY_CA" ]; then
    log "HttpCanary CA 不存在，跳过（未解锁 / 未安装）"
    exit 1
fi
if [ ! -d "$WORK" ]; then
    log "挂载源 $WORK 缺失，跳过（post-fs-data 未建成）"
    exit 1
fi

# 目标文件名沿用 certs/ 下已有证书名（同 CN 重建后哈希不变）
name=$(basename "$(ls "$CERTS"/*.0 2>/dev/null | head -1)" 2>/dev/null)
[ -z "$name" ] && name=87bc3517.0
target=$WORK/$name

if [ -f "$target" ] && cmp -s "$target" "$CANARY_CA"; then
    log "已是最新 ($name)"
    exit 0
fi

cp -f "$CANARY_CA" "$target" || { log "写挂载源失败"; exit 1; }
chown 0:0 "$target" 2>/dev/null
chmod 644 "$target" 2>/dev/null
chcon u:object_r:system_file:s0 "$target" 2>/dev/null

# 同步回模块目录，保证下次开机 post-fs-data 直接拷到新证书
cp -f "$CANARY_CA" "$CERTS/$name" 2>/dev/null
chown 0:0 "$CERTS/$name" 2>/dev/null
chmod 644 "$CERTS/$name" 2>/dev/null

# 保险：若挂载不存在则重建（已挂载时 bind 会失败，忽略）
mount --bind "$WORK" "$APEX" 2>/dev/null
[ -d "$SYS" ] && mount --bind "$WORK" "$SYS" 2>/dev/null

ok=0
for p in "$APEX/$name" "$SYS/$name"; do
    [ -f "$p" ] && cmp -s "$p" "$CANARY_CA" && ok=$((ok + 1))
done
log "已更新 $name，生效路径 $ok/2"
[ "$ok" -ge 1 ]
