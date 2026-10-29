#!/system/bin/sh
# late_start 阶段的兜底：若 post-fs-data 时 APEX 还没挂好，这里重建并补挂；
# 并对启动较早的应用进程用 nsenter 补挂到它的 mount namespace

MODDIR=${0%/*}
WORK=/data/local/tmp/hc_cacerts
LOG=/data/local/tmp/hc_cacert.log
APEX=/apex/com.android.conscrypt/cacerts
SYS=/system/etc/security/cacerts
CERTS=$MODDIR/certs

echo "--- $(date) service.sh ---" >> "$LOG"

N=0
for f in "$CERTS"/*.0; do
    [ -f "$f" ] && N=$((N + 1))
done
if [ "$N" -eq 0 ]; then
    echo "abort: certs 目录为空" >> "$LOG"
    exit 0
fi

# 等系统稳定（开机时 APEX 可能刚挂）
i=0
while [ $i -lt 20 ]; do
    [ "$(ls "$APEX" 2>/dev/null | wc -l)" -gt 50 ] && break
    sleep 1
    i=$((i + 1))
done

# 若 post-fs-data 没做出合并目录，这里重建一次
if [ ! -f "$WORK/$(ls "$CERTS" | head -1)" ]; then
    BASE=$(ls "$APEX" 2>/dev/null | wc -l)
    if [ "$BASE" -gt 50 ]; then
        rm -rf "$WORK"
        mkdir -p "$WORK"
        cp -f "$APEX"/* "$WORK"/ 2>>"$LOG"
        cp -f "$CERTS"/*.0 "$WORK"/ 2>>"$LOG"
        NEW=$(ls "$WORK" 2>/dev/null | wc -l)
        if [ "$NEW" -lt "$((BASE + N))" ]; then
            echo "abort: 拷贝不完整" >> "$LOG"
            rm -rf "$WORK"
            exit 0
        fi
        chown -R 0:0 "$WORK"
        chmod 755 "$WORK"
        chmod 644 "$WORK"/*
        chcon -R u:object_r:system_file:s0 "$WORK" 2>>"$LOG"
        echo "rebuilt WORK new=$NEW" >> "$LOG"
    else
        echo "abort: APEX 不可用" >> "$LOG"
        exit 0
    fi
fi

# 1) 当前(全局)命名空间
mount --bind "$WORK" "$APEX" 2>>"$LOG"
if [ -d "$SYS" ]; then
    mount --bind "$WORK" "$SYS" 2>>"$LOG"
fi

# 2) 已有进程(仅 uid>=10000 的应用)补挂
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    uid=$(stat -c %u "$d" 2>/dev/null)
    [ -z "$uid" ] && continue
    [ "$uid" -lt 10000 ] && continue
    target="/proc/$p/root"
    [ -d "$target$APEX" ] || continue
    nsenter -t "$p" -m -- mount --bind "$WORK" "$APEX" 2>/dev/null && echo "nsenter mount pid=$p" >> "$LOG"
done

echo "done: apex=$(ls "$APEX" 2>/dev/null | wc -l) sys=$(ls "$SYS" 2>/dev/null | wc -l)" >> "$LOG"
exit 0
