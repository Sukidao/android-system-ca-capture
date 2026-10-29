#!/system/bin/sh
# 开机早期(post-fs-data, zygote 启动前)把 certs/ 下的自签 CA 合并进系统证书库并 bind mount
# 任一步失败都只写日志、不挂载，避免把 TLS 搞坏

MODDIR=${0%/*}
WORK=/data/local/tmp/hc_cacerts
LOG=/data/local/tmp/hc_cacert.log
APEX=/apex/com.android.conscrypt/cacerts
SYS=/system/etc/security/cacerts
CERTS=$MODDIR/certs

echo "=== $(date) post-fs-data ===" > "$LOG"

# 统计待装证书数量（文件名必须是 <subject_hash_old>.0）
N=0
for f in "$CERTS"/*.0; do
    [ -f "$f" ] && N=$((N + 1))
done
if [ "$N" -eq 0 ]; then
    echo "abort: $CERTS 下没有 *.0 证书" >> "$LOG"
    exit 0
fi

SRC=""
if [ -d "$APEX" ] && [ "$(ls "$APEX" 2>/dev/null | wc -l)" -gt 50 ]; then
    SRC=$APEX
elif [ -d "$SYS" ] && [ "$(ls "$SYS" 2>/dev/null | wc -l)" -gt 50 ]; then
    SRC=$SYS
fi
if [ -z "$SRC" ]; then
    echo "abort: 系统证书库未就绪" >> "$LOG"
    exit 0
fi

BASE=$(ls "$SRC" 2>/dev/null | wc -l)
rm -rf "$WORK"
mkdir -p "$WORK"
cp -f "$SRC"/* "$WORK"/ 2>>"$LOG"
cp -f "$CERTS"/*.0 "$WORK"/ 2>>"$LOG"
NEW=$(ls "$WORK" 2>/dev/null | wc -l)
echo "src=$SRC base=$BASE certs=$N new=$NEW" >> "$LOG"

# 保险：数量必须 = 原数量 + 待装数量，否则说明拷贝不完整，直接放弃
if [ "$NEW" -lt "$((BASE + N))" ]; then
    echo "abort: 拷贝不完整，不挂载" >> "$LOG"
    exit 0
fi

chown -R 0:0 "$WORK" 2>>"$LOG"
chmod 755 "$WORK"
chmod 644 "$WORK"/* 2>>"$LOG"
chcon -R u:object_r:system_file:s0 "$WORK" 2>>"$LOG"

if mount --bind "$WORK" "$APEX" 2>>"$LOG"; then
    echo "mounted $APEX -> $(ls "$APEX" 2>/dev/null | wc -l)" >> "$LOG"
else
    echo "mount fail: $APEX" >> "$LOG"
fi

if [ -d "$SYS" ]; then
    if mount --bind "$WORK" "$SYS" 2>>"$LOG"; then
        echo "mounted $SYS -> $(ls "$SYS" 2>/dev/null | wc -l)" >> "$LOG"
    else
        echo "mount fail: $SYS" >> "$LOG"
    fi
fi
exit 0
