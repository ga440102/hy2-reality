# hy2/reality 一键脚本

Hysteria2 + VLESS Reality 二合一安装脚本。

## 一键安装（root）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh)
```

运行后按菜单选 1（Hysteria2）或 2（Reality），装完一个可继续装另一个。

## 直接指定协议

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) hy2
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) reality
```

注意：云服务器安全组需手动放行对应端口（HY2 默认 UDP 8443，Reality 默认 TCP 8880）。
