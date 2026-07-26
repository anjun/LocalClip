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
- 全局快捷键 **⌥C** 切换历史面板
- 面板内 **↑/↓** 选择、**Return** 粘贴（与点击同一路径）
- 默认登录启动（签名/包结构不完整时可能注册失败，可忽略）

## 要求

- macOS 13+
- Swift 5.9+（Command Line Tools 或 Xcode）
- 自动粘贴：系统设置 → 隐私与安全性 → **辅助功能** → 勾选 LocalClip

## 构建与运行

```bash
cd /Users/alex/PycharmProjects/LocalClip

# 核心逻辑自测
make test
# 或: swift run LocalClipTestRunner

# 发布：Intel (x86_64) + Apple 芯片 (arm64) 二合一通用包
make release
# 产物:
#   dist/LocalClip.app
#   dist/LocalClip-1.0.0-universal-macos.zip
#   dist/LocalClip-1.0.0-universal-macos.dmg
# 并安装到 ~/Applications/LocalClip.app

# 仅本机架构快速打包（开发用）
make package

# 推荐从「应用程序」启动（权限更稳定）
make open
# 或: open ~/Applications/LocalClip.app
```

通用二进制用 `lipo` 合并 arm64 与 x86_64，单包可在 Intel Mac 与 Apple 芯片 Mac 上运行（需 macOS 13+）。
### 菜单栏操作

| 操作 | 作用 |
|------|------|
| **左键** 图标 | 打开历史面板 |
| **⌥C** | 全局切换历史面板 |
| **右键** 图标 | 菜单：偏好设置 / 辅助功能 / **退出并重新打开** / **退出** |
| 面板 **↑/↓** + **Return** | 选择并粘贴（与点击相同） |
| 面板底部 **退出** | 退出应用 |

### 辅助功能（自动粘贴）

1. 打开 **系统设置 → 隐私与安全性 → 辅助功能**，勾选 **LocalClip**  
2. 若面板仍提示未信任：右键图标 → **退出并重新打开**  
3. 重打包后若自动粘贴失效：在辅助功能列表中 **关掉再打开** LocalClip，然后退出并重新打开 App  

未授权时仍可点选条目写入剪贴板，再手动 ⌘V。

右键 **偏好设置…** 可开关登录启动等本应用设置。

## 数据位置

```
~/Library/Application Support/LocalClip/
  db.sqlite
  images/
  thumbs/
```

## 快捷键

| 快捷键 | 作用 |
|--------|------|
| **⌥C** | 全局显示/隐藏历史面板（Carbon 热键，固定 v1） |
| **↑ / ↓** | 面板内移动选择（搜索框聚焦时交给输入） |
| **Return** | 粘贴当前选中项 |
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
