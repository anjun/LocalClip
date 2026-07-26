# LocalClip

[English](README.en.md) · **中文**

纯本地的 macOS 菜单栏剪贴板历史。记录文本与图片，不上传、不账号、默认不联网。

[![CI](https://github.com/anjun/LocalClip/actions/workflows/ci.yml/badge.svg)](https://github.com/anjun/LocalClip/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/anjun/LocalClip)](https://github.com/anjun/LocalClip/releases)

## 为什么用 LocalClip

- **只在本机**：历史存在 `~/Library/Application Support/LocalClip/`，无云同步、无分析
- **菜单栏常驻**：无 Dock 图标，需要时再唤出
- **文本 + 图片**：截图与复制内容一并保留
- **一键粘贴**：点选或 Return 写回剪贴板并自动粘贴（需辅助功能）
- **可审计**：MIT 开源；仅在你主动「检查更新」时访问 GitHub

## 安装

从 [Releases](https://github.com/anjun/LocalClip/releases) 下载 `.dmg` 或 `.zip`，将 **LocalClip.app** 拖到「应用程序」。

首次使用自动粘贴时，请在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选 LocalClip。若改过权限，右键菜单栏图标选择 **退出并重新打开**。

要求：macOS 13+（发布包为 Apple 芯片 / Intel 通用二进制）。

## 使用

| 操作 | 作用 |
|------|------|
| 左键菜单栏图标 | 打开历史 |
| **⌥C** | 全局显示 / 隐藏 |
| **↑ / ↓** + **Return** | 选择并粘贴 |
| 点选一条历史 | 写入剪贴板并尝试粘贴 |
| 右键图标 | 偏好设置、检查更新、退出 |

面板内可搜索文本、切换「纯文本」粘贴（仅影响文本）。默认最多保留 **200 条 / 7 天**。

## 隐私

| | |
|--|--|
| 剪贴板历史 | 仅本机 Application Support |
| 网络 | **默认无**；仅「检查更新」请求 GitHub Releases |
| 账号 / 分析 / iCloud | 无 |

## 从源码构建

```bash
git clone https://github.com/anjun/LocalClip.git
cd LocalClip
make test
make package   # → ~/Applications/LocalClip.app
```

通用发布包：`make release`。推送 `v*` 标签可由 GitHub Actions 自动构建 Release。

## 许可证

[MIT](LICENSE) © 2026 anjun
