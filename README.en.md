# LocalClip

**[中文](README.md)** · English

Local-only clipboard history for the macOS menu bar. Text and images stay on your machine — no account, no cloud, no network by default.

[![CI](https://github.com/anjun/LocalClip/actions/workflows/ci.yml/badge.svg)](https://github.com/anjun/LocalClip/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/anjun/LocalClip)](https://github.com/anjun/LocalClip/releases)

## Why LocalClip

- **On-device only** — history lives under `~/Library/Application Support/LocalClip/`; no sync, no analytics
- **Menu bar app** — no Dock icon; open when you need it
- **Text + images** — screenshots and copy content in one place
- **Quick capture** — press **⌥A** to select a window or free region, resize it, then copy the PNG into history
- **Paste in one step** — click or Return writes the pasteboard and auto-pastes (Accessibility)
- **Auditable** — MIT-licensed; talks to GitHub only when you **Check for Updates**

## Install

Download a `.dmg` or `.zip` from [Releases](https://github.com/anjun/LocalClip/releases) and drag **LocalClip.app** into Applications.

For auto-paste, enable LocalClip under **System Settings → Privacy & Security → Accessibility**. After changing permissions, right-click the status item → **Quit and reopen**.

Quick capture needs **Screen & System Audio Recording** access; see the next section. Keep only one `LocalClip.app` copy.

Requires macOS 13+ (universal arm64 + x86_64 builds).

## Quick capture

Press **⌥A** (customizable) to capture. Hover over a window to select its bounds, then click to lock the selection. Drag an edge or one of the eight handles to resize, or drag inside the selection to move it. You can also drag directly to draw a free region. Press **Enter**, double-click the selection, or click **Done** to copy; **Escape** cancels and right-click starts a new selection.

The selector shows the screen as it looked when capture began. The completed PNG is copied to the system pasteboard and stored as a normal image in LocalClip history, without saving to the Desktop. Temporary screen images are deleted immediately after they are read.

You can also right-click the status item → **Region capture**. In **Preferences → Quick capture**, disable the global shortcut (the menu item still works), record a new combination, or restore the default **⌥A**.

The first capture requests **Screen & System Audio Recording** if LocalClip cannot yet see other apps’ windows. After you allow it, **quit LocalClip completely and reopen**, then press the shortcut again. Without this grant, the selection UI may still appear, but the result is often only the desktop wallpaper, followed by another permission prompt.

If the system toggle looks on but the shot is the desktop and windows such as WeChat are missing:

1. Keep only one LocalClip copy
2. System Settings → Privacy & Security → Screen & System Audio Recording
3. Remove every LocalClip entry, add the current `LocalClip.app`, and enable it
4. Quit LocalClip fully, reopen it, focus the target window, and press the shortcut

Source builds and current releases use ad-hoc signing. If an update drops the grant, repeat the steps above once.

## Usage

| Action | Effect |
|--------|--------|
| Left-click status item | Open history |
| **⌥C** | Toggle panel globally |
| **⌥A** | Quick region capture (configurable; can be disabled) |
| **↑ / ↓** + **Return** | Select and paste |
| Click a row | Write pasteboard + try auto-paste |
| Right-click status item | Region capture, preferences, updates, quit |

Search text in the panel. With **Plain text** off (the default), pasting from history preserves the source's RTF, RTFD, and HTML representations, including fonts, colors, links, and lists where supported by the receiving app. Turn it on to paste text without formatting; images are unaffected. History previews and search still use plain text. Entries captured before this feature need to be copied again to retain their formatting.

Preferences lets you set the item-count limit and retention duration independently; the default remains **200 items / 7 days**. Choosing a permanent duration disables age-based cleanup, while the item-count limit continues to apply.

## Privacy

| | |
|--|--|
| Clipboard history | Local Application Support only |
| Network | **None by default**; update check hits GitHub Releases only when requested |
| Accounts / analytics / iCloud | None |

## Build from source

```bash
git clone https://github.com/anjun/LocalClip.git
cd LocalClip
make test
make package   # → updates the existing install location (or a writable Applications folder)
```

Universal release bundle: `make release`. `make public` refreshes local `dist/` first, then pushes a `v*` tag for GitHub Actions to publish.

## License

[MIT](LICENSE) © 2026 anjun
