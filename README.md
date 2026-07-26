# LocalClip

[English](README.en.md) · **中文**

**纯本地** macOS 菜单栏剪贴板历史：文本 + 图片。  
源码可审计；默认不联网。仅在你点击「检查更新」时访问 GitHub Releases。

[![CI](https://github.com/anjun/LocalClip/actions/workflows/ci.yml/badge.svg)](https://github.com/anjun/LocalClip/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/anjun/LocalClip)](https://github.com/anjun/LocalClip/releases)

## 功能

- 菜单栏常驻（`LSUIElement`，无 Dock 图标）
- 记录文本与图片；同一次复制若图文并存 → **两条**（列表中图在上）
- 按类型相邻去重；保留 **最多 200 条** 且 **7 天**
- 文本搜索；点选 / **Return** 写入剪贴板并 **自动粘贴**（需辅助功能）
- 纯文本开关（仅影响文本）
- 全局快捷键 **⌥C** 切换面板；面板内 **↑/↓** 选择
- 登录时启动（偏好设置中可关）
- **检查更新 / 立即更新**：从 GitHub Releases 下载通用 zip 并自动替换安装（仅用户点击时联网）

## 系统要求

- macOS 13+
- Apple 芯片或 Intel（发布包为 **arm64 + x86_64** 通用二进制）

## 安装

### 下载安装包（推荐）

1. 打开 [Releases](https://github.com/anjun/LocalClip/releases) 下载 `.dmg` 或 `.zip`
2. 将 **LocalClip.app** 拖到「应用程序」
3. **系统设置 → 隐私与安全性 → 辅助功能** → 勾选 LocalClip  
4. 若改过权限：右键菜单栏图标 → **退出并重新打开**

### 从源码构建

```bash
git clone https://github.com/anjun/LocalClip.git
cd LocalClip

make test          # 单元测试
make package       # 本机架构 .app → ~/Applications
make release       # 通用 ZIP + DMG
make open
```

## 使用

| 操作 | 作用 |
|------|------|
| **左键** 菜单栏图标 | 打开历史面板 |
| **⌥C** | 全局显示/隐藏面板 |
| **↑ / ↓** + **Return** | 选择并粘贴 |
| **右键** 图标 | 偏好设置 / 检查更新 / 辅助功能 / 退出 |
| 点选历史项 | 写剪贴板 + 尝试自动粘贴 |

## 开发与发布

```bash
# 本地通用包
make release

# 打 tag 并推送 → GitHub Actions 自动构建并上传 Release 产物
make public
# 或指定版本：
make public VERSION=1.0.1
```

- **CI**：推送到 `main` / PR 时跑测试与编译（`.github/workflows/ci.yml`）
- **Release**：推送 `v*` 标签时打通用包并创建 GitHub Release（`.github/workflows/release.yml`）

## 隐私

| 数据 | 说明 |
|------|------|
| 剪贴板历史 | 仅 `~/Library/Application Support/LocalClip/` |
| 网络 | **默认无**；仅「检查更新」请求 `api.github.com` 最新 Release |
| 分析 / 账号 / iCloud | 无 |

## 架构

| 模块 | 说明 |
|------|------|
| `LocalClipCore` | 存储、监听、粘贴策略、热键、更新检查 |
| `LocalClipApp` | 菜单栏 UI / 偏好设置 |
| `LocalClipTestRunner` | 无 XCTest 环境下的轻量测试 |

## 许可证

[MIT](LICENSE) © 2026 anjun
