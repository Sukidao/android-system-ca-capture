#!/system/bin/sh
# action.sh —— KernelSU 管理器模块卡片上的「执行」按钮
# 用途：HttpCanary 重置证书后，点一下即同步 + 重启相关应用，免重启手机

MODDIR=${0%/*}
LOG=/data/local/tmp/hc_cacert.log

echo "=== 同步 HttpCanary 根证书 ==="
sh "$MODDIR/sync_ca.sh"
rc=$?

if [ "$rc" -eq 0 ]; then
    echo "同步成功，重启应用以清空证书缓存..."
    am force-stop com.guoshi.httpcanary 2>/dev/null
    am force-stop com.tencent.mm 2>/dev/null
    echo ""
    echo "完成：请在 HttpCanary 重新开始抓包，微信重新打开。"
else
    echo "同步失败（rc=$rc）"
fi

echo ""
echo "--- 最近日志 ---"
tail -8 "$LOG" 2>/dev/null
exit "$rc"
