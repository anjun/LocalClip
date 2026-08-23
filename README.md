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
- **快速截屏**：按 **⌥A** 调出 macOS 原生选区，图片立即复制并进入历史
- **一键粘贴**：点选或 Return 写回剪贴板并自动粘贴（需辅助功能）
- **可审计**：MIT 开源；仅在你主动「检查更新」时访问 GitHub

## 安装

从 [Releases](https://github.com/anjun/LocalClip/releases) 下载 `.dmg` 或 `.zip`，将 **LocalClip.app** 拖到「应用程序」。

首次使用自动粘贴时，请在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选 LocalClip。若改过权限，右键菜单栏图标选择 **退出并重新打开**。

快速截屏需要 **屏幕与系统音频录制** 权限，详见下一节。请只保留一份 `LocalClip.app`。

要求：macOS 13+（发布包为 Apple 芯片 / Intel 通用二进制）。

## 快速截屏

按 **⌥A**（可改）调出 macOS 原生选区：拖动选择区域，Esc 取消。成功后 PNG 立刻进入系统剪贴板，并作为普通图片写入 LocalClip 历史，没有预览窗口，也不会保存到桌面。选区过程使用临时文件，写入完成后立即删除。

也可以右键菜单栏图标选择 **区域截屏**。在「偏好设置 → 快速截屏」里可以关闭全局快捷键（右键菜单仍可用）、录制新组合，或恢复默认 **⌥A**。

第一次截屏时，若还不能截到其他应用的窗口，macOS 会请求 **屏幕与系统音频录制**。点允许后必须 **完全退出并重新打开** LocalClip，再按一次快捷键。没有这项权限时，选区界面仍可能出现，但结果往往只有桌面壁纸，截完还会再次弹出授权框。

若系统开关看起来已经打开，截到的却是桌面、微信等窗口是空的：

1. 只保留一份 LocalClip
2. 系统设置 → 隐私与安全性 → 屏幕与系统音频录制
3. 删掉列表里所有 LocalClip，再把当前的 `LocalClip.app` 加回去并打开
4. 完全退出 LocalClip 后重新打开，回到目标窗口再按快捷键

源码构建和当前发布包使用 ad-hoc 签名。更新后若权限失效，按上面步骤重新授权一次即可。

## 使用

| 操作 | 作用 |
|------|------|
| 左键菜单栏图标 | 打开历史 |
| **⌥C** | 全局显示 / 隐藏 |
| **⌥A** | 快速区域截屏（可修改或关闭） |
| **↑ / ↓** + **Return** | 选择并粘贴 |
| 点选一条历史 | 写入剪贴板并尝试粘贴 |
| 右键图标 | 区域截屏、偏好设置、检查更新、退出 |

面板内可搜索文本、切换「纯文本」粘贴（仅影响文本）。在「偏好设置」中可以分别调整最多保留的条数和保留时长；默认仍为 **200 条 / 7 天**。将时长设为「永久」会停用按时间清理，但条数上限仍会继续生效。

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
make package   # → 更新现有安装位置；没有旧版时选择可写的 Applications
```

通用发布包：`make release`。`make public` 会先刷新本地 `dist/`，再推送 `v*` 标签并由 GitHub Actions 发布 Release。

## 许可证

[MIT](LICENSE) © 2026 anjun
