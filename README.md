<h1 align="center">Aether Mail</h1>

<p align="center">
  <b>A private, AI‑native email client for iPhone &amp; iPad.</b><br>
  The iOS sibling of <a href="https://github.com/ic3y808/aether-courier">Aether Courier</a> (macOS) — it shares the same self‑contained mail engine and keeps the AI on <b>your</b> devices.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/iOS%2FiPadOS-26-8d5cf7?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-ec4899?logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-3b82f6">
  <img alt="Status" src="https://img.shields.io/badge/status-early%20(WIP)-orange">
</p>

---

> ### 🚧 Early / work‑in‑progress
> **Now:** onboarding + **multiple real accounts** over live IMAP (`EmailKit`) — add iCloud / Gmail / Outlook / any IMAP host with an app‑specific password, and it fetches your actual inbox. Unified inbox, reading (MIME‑parsed bodies), per‑account management. Credentials live in the Keychain.
> **Next:** OAuth sign‑in (Gmail/Outlook), IMAP IDLE push, and the tiered on‑device → Mac → cloud AI.

## Why

Most "AI email" apps ship your mail to someone else's servers. Aether Mail is the opposite: the **mail engine is self‑contained** (IMAP/SMTP/MIME/OAuth over Network.framework, zero third‑party dependencies), and the AI is designed to run **locally** — on the device's Neural Engine, or on a Mac you own running large local models, before ever considering a remote host.

The mail engine — the **[`EmailKit`](EmailKit/)** Swift package — is the **exact same code** that powers the macOS [Aether Courier](https://github.com/ic3y808/aether-courier) client (vendored here so this repo builds standalone).

## AI (planned)

The Copilot will route in preference order, per task:

1. **Your Mac** running Ollama / LM Studio (the biggest models) when reachable — *preferred*
2. **A remote host** you configure, when the Mac isn't reachable
3. **On‑device** (Apple Foundation Models) for quick / offline tasks

No account and no server of ours ever sees your mail. (The author's private hub endpoints are **not** part of this public app.)

## Build

Requires **Xcode 26+** and [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/ic3y808/aether-mail.git
cd aether-mail
./build.sh            # build for the iOS Simulator
./build.sh --install  # build, install and launch in the Simulator
./build.sh --device   # build for a physical iPhone/iPad
```

The `.xcodeproj`, `Info.plist` and entitlements are **generated from `project.yml`** and gitignored — never hand‑edit them.

## License

MIT — see [LICENSE](LICENSE). Built with SwiftUI and EmailKit.
