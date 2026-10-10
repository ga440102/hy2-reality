# hy2/reality 一键脚本

Hysteria2 + VLESS Reality 二合一安装脚本。

安装 HY2 前脚本会自动测速：下载、上传各测 3 次，取中位数 × 0.8 作为带宽参数，启用 Brutal 拥塞控制。测速失败时会让你选择重测 / 降级 BBR 安装 / 退出，不会自动替你决定。

## 一键运行（root）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ga440102/hy2-reality/main/hy2-reality.sh)
```

菜单会先显示各协议的已安装状态（端口、运行状态），然后可选：1/2 安装（重装会覆盖已有安装）、3 查看已安装节点信息、4/5 卸载、0 退出。安装/卸载/查看完成后按任意键返回主菜单。
