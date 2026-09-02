# MoonProwl Browser

A lightweight WebKit browser for macOS. Built on the system WebKit engine, with
privacy-oriented defaults and no telemetry or network calls back to a server.

## What it is

- macOS desktop app, built from a single `main.swift`.
- No account, no sync, no analytics.
- Default-protective settings that apply for the session only (they reset when
  you quit).

## Default settings

| Control | Default | What it does |
|---|---|---|
| JavaScript | off | Global switch — scripts disabled until you allow them. |
| Tracker / ad blocking | on | Network requests to known ad and analytics domains are blocked via a WebKit content rule list (see `blocklist.json`). |
| Third-party cookies | blocked | Cross-site cookies are not stored. |
| YouTube ad-privacy | on | Rotates the `VISITOR_INFO1_LIVE` cookie and sets `PREF=f2=8000000&f6=2` on youtube.com only. Local-only. |
| Pop-up blocking | on | `window.open` / `target=_blank` are denied. |
| User-Agent | generic | Reports a common Chrome UA instead of exposing the browser/OS. |
| Reset memory on refresh | off | When on, wipes cookies, cache, and local storage on every page reload. |

HTTPS-Only mode was removed — plaintext http:// loads with no blocking.

## Installing
Go to the official website: https://browser.html-5.me/

## Building

Requires macOS with Xcode tools installed (for `swiftc`).

```bash
./build.sh
```

This produces `build/MoonProwl Browser.app` (universal: arm64 + x86_64),
ad-hoc signed. To install it somewhere else, move/copy the `.app`.

The build script also copies `Info.plist`, `entitlements.plist`, `blocklist.json`,
and an icon into the bundle.

## Running / redistributing

The app is ad-hoc signed and not notarized. After dragging it to Applications,
macOS may flag it on first launch. If it just bounces:

1. Right-click the app in Finder and choose **Open** — the dialog will appear, click Open.
2. Or, in Terminal once: `xattr -dr com.apple.quarantine "/Applications/MoonProwl Browser.app"`
   then open it from Finder/Spotlight.

On a fresh machine with no prior state, the download is flagged by Gatekeeper as a
downloaded app, so step 1 or 2 is needed for the first launch.

## License

MIT. See `LICENSE`. Free for personal, non-commercial use only.
Commercial use, redistribution of modified versions, and sublicensing are not
permitted under the current terms.

## Source

Single-file app written in Swift. The privacy behavior lives in `main.swift`; the
blocklist lives in `blocklist.json`.

## Reads

- On-disk data goes to `~/Library/Application Support/MoonProwl Browser/` (only
  saved passwords and bookmarks, if you save any). Nothing is sent to a server.
