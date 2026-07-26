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
- **Paste in one step** — click or Return writes the pasteboard and auto-pastes (Accessibility)
- **Auditable** — MIT-licensed; talks to GitHub only when you **Check for Updates**

## Install

Download a `.dmg` or `.zip` from [Releases](https://github.com/anjun/LocalClip/releases) and drag **LocalClip.app** into Applications.

For auto-paste, enable LocalClip under **System Settings → Privacy & Security → Accessibility**. After changing permissions, right-click the status item → **Quit and reopen**.

Requires macOS 13+ (universal arm64 + x86_64 builds).

## Usage

| Action | Effect |
|--------|--------|
| Left-click status item | Open history |
| **⌥C** | Toggle panel globally |
| **↑ / ↓** + **Return** | Select and paste |
| Click a row | Write pasteboard + try auto-paste |
| Right-click status item | Preferences, updates, quit |

Search text in the panel; optional plain-text paste (text only). Keeps up to **200 items / 7 days**.

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
make package   # → ~/Applications/LocalClip.app
```

Universal release bundle: `make release`. Pushing a `v*` tag can publish via GitHub Actions.

## License

[MIT](LICENSE) © 2026 anjun
