# LocalClip

**[中文](README.md)** · English

**Local-only** macOS menu bar clipboard history for text and images.  
Auditable source. No network by default — the app only contacts GitHub when you click **Check for Updates**.

[![CI](https://github.com/anjun/LocalClip/actions/workflows/ci.yml/badge.svg)](https://github.com/anjun/LocalClip/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/anjun/LocalClip)](https://github.com/anjun/LocalClip/releases)

## Features

- Menu bar only (`LSUIElement`, no Dock icon)
- Captures text and images; dual pasteboard content → **two rows** (image first)
- Adjacent same-kind dedupe; retain **max 200 items** and **7 days**
- Text search; click / **Return** writes pasteboard and **auto-pastes** (Accessibility)
- Plain-text paste toggle (text only)
- Global hotkey **⌥C**; in-panel **↑/↓** selection
- Launch at login (toggle in Preferences)
- **Check for Updates / Install now**: download universal zip from GitHub Releases and replace the app (network only when you click)

## Requirements

- macOS 13+
- Apple silicon or Intel (release builds are **universal arm64 + x86_64**)

## Install

### From Releases (recommended)

1. Download `.dmg` or `.zip` from [Releases](https://github.com/anjun/LocalClip/releases)
2. Drag **LocalClip.app** to Applications
3. **System Settings → Privacy & Security → Accessibility** → enable LocalClip  
4. After changing permissions: right-click status item → **Quit and reopen**

### From source

```bash
git clone https://github.com/anjun/LocalClip.git
cd LocalClip

make test
make package       # host-arch .app → ~/Applications
make release       # universal ZIP + DMG
make open
```

## Usage

| Action | Effect |
|--------|--------|
| **Left-click** status item | Open history panel |
| **⌥C** | Toggle panel globally |
| **↑ / ↓** + **Return** | Select and paste |
| **Right-click** status item | Preferences / updates / Accessibility / Quit |
| Click a history row | Pasteboard write + auto-paste attempt |

## Develop & publish

```bash
make release

# Tag + push → GitHub Actions builds assets and creates a Release
make public
make public VERSION=1.0.1
```

- **CI** on `main` / PR: tests + build (`.github/workflows/ci.yml`)
- **Release** on `v*` tags: universal package + GitHub Release (`.github/workflows/release.yml`)

## Privacy

| Data | Policy |
|------|--------|
| Clipboard history | Only under `~/Library/Application Support/LocalClip/` |
| Network | **None by default**; update check hits `api.github.com` only when requested |
| Analytics / accounts / iCloud | None |

## Architecture

| Module | Role |
|--------|------|
| `LocalClipCore` | Store, monitor, paste policy, hotkey, update check |
| `LocalClipApp` | Menu bar UI / preferences |
| `LocalClipTestRunner` | Lightweight tests without XCTest |

## License

[MIT](LICENSE) © 2026 anjun
