# hy2/reality 一键脚本

Hysteria2 + VLESS Reality 二合一安装脚本。

## 一键运行（root）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh)
```

菜单会先显示各协议的已安装状态（端口、运行状态），然后可选：1/2 安装（重装会覆盖已有安装）、3/4 卸载、0 退出。

## 直接指定协议

只装 Hysteria2：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) hy2
```

只装 Reality：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) reality
```

## 卸载

卸载 Hysteria2：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) uninstall-hy2
```

卸载 Reality：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh) uninstall-reality
```

注意：云服务器安全组需手动放行对应端口（HY2 默认 UDP 8443，Reality 默认 TCP 8880）；卸载后安全组规则如不再需要请手动删除。
