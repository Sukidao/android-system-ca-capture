# 证书放这里

把你抓包工具的根证书（PEM 格式）放到本目录，**文件名必须**是它的 `subject_hash_old` 加 `.0`：

```sh
openssl x509 -in your_ca.pem -noout -subject_hash_old
# 输出例如 87bc3517 → 重命名为 87bc3517.0
```

可以放多张，模块会全部合并进系统证书库。

获取各工具根证书的方法：

| 工具 | 位置 / 导出方式 |
|---|---|
| HttpCanary | `设置 → 证书 → 导出`，或从 `/data/data/com.guoshi.httpcanary/files/backup/HttpCanary.pem` 取（需 root） |
| Charles | `Help → SSL Proxying → Save Charles Root Certificate…`（选 PEM） |
| mitmproxy | `~/.mitmproxy/mitmproxy-ca-cert.pem` |
| Reqable / Burp | 导出 DER/PEM 后 `openssl x509 -inform der -in cert.der -out ca.pem` 转换 |

> 仓库不包含任何证书文件，请使用你自己的 CA。
