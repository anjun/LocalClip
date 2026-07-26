# LocalClip

**纯本地** macOS 菜单栏剪贴板历史：文本 + 图片，**零联网**。

替代 iCopy 一类闭源工具时，你可以用源码自行审计——工程内不包含 `URLSession`、分析 SDK 或更新检查。

## 功能（v1）

- 菜单栏常驻（`LSUIElement`，无 Dock 图标）
- 记录文本与图片；同一次复制若图文并存 → **两条**（列表中图在上）
- 按类型相邻去重（相同 hash 不重复记）
- 保留：**最多 200 条** 且 **7 天**
- 文本搜索（大小写不敏感）；搜索时不显示纯图片项
- 点选：写入系统剪贴板 + **自动粘贴**（需辅助功能）；未授权时仅写剪贴板
- 纯文本开关：仅影响文本；图片仍粘贴为图片
- 默认登录启动（签名/包结构不完整时可能注册失败，可忽略）

## 要求

- macOS 13+
- Swift 5.9+（Command Line Tools 或 Xcode）
- 自动粘贴：系统设置 → 隐私与安全性 → **辅助功能** → 勾选 LocalClip

## 构建与运行

```bash
cd /Users/alex/PycharmProjects/LocalClip

# 核心逻辑自测（Command Line Tools 无 XCTest 时使用内置 runner）
swift run LocalClipTestRunner

# 打包 .app
./Scripts/package-app.sh

# 启动
open dist/LocalClip.app
```

开发态直接跑可执行文件：

```bash
swift run LocalClip
```

首次自动粘贴前请在辅助功能中授权；否则点选后手动 ⌘V 即可。

## 数据位置

```
~/Library/Application Support/LocalClip/
  db.sqlite
  images/
  thumbs/
```

## 快捷键

菜单栏图标打开面板（系统 MenuBarExtra）。默认不强制全局热键依赖（避免额外 Input Monitoring 复杂度）；点菜单栏图标即可。

## 隐私

- 无网络代码路径
- 无 iCloud / 账号 / 分析
- 历史仅存本机

## 架构

| 模块 | 说明 |
|------|------|
| `LocalClipCore` | 存储、去重、保留、粘贴策略、监听 |
| `LocalClipApp` | SwiftUI 菜单栏 UI |

设计文档：`docs/superpowers/specs/2026-07-26-localclip-design.md`
