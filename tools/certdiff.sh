#!/bin/sh
# 自检：HttpCanary 当前根证书 与 系统证书库内 <hash>.0 是否一致
# 用法：sh certdiff.sh <设备地址>
# 输出：SAME（一致，抓包应正常） / DIFF（证书已被重建，需重新部署）

D=$1
TMP=${TMPDIR:-/tmp}
CA_SYS=$TMP/_ca_sys.pem
CA_APP=$TMP/_ca_app.pem

adbs() { adb -s "$D" "$@"; }

adbs exec-out "su -c 'cat /apex/com.android.conscrypt/cacerts/<hash>.0'" > "$CA_SYS" 2>/dev/null
adbs exec-out "su -c 'cat /data/data/com.guoshi.httpcanary/files/backup/HttpCanary.pem'" > "$CA_APP" 2>/dev/null

finger() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'; }

FS=$(finger "$CA_SYS")
FA=$(finger "$CA_APP")

echo "system : $FS"
echo "canary : $FA"

if [ -z "$FS" ] || [ -z "$FA" ]; then
    echo "ERROR: 读取失败（检查 root / 设备连接 / HttpCanary 是否已生成证书）"
    exit 2
fi

if [ "$FS" = "$FA" ]; then
    echo "SAME"
else
    echo "DIFF  <-- 证书已被重建，需重新部署（见 docs 第十节）"
    exit 1
fi
