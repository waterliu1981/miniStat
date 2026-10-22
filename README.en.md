<div align="center">

# miniStat

**A tiny, beautiful CPU / GPU / Memory / Disk monitor for the macOS menu bar.**

Four numbers you actually care about. Nothing else.

[![Release](https://img.shields.io/github/v/release/waterliu1981/miniStat?color=blue)](https://github.com/waterliu1981/miniStat/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/waterliu1981/miniStat)
[![CPU](https://img.shields.io/badge/CPU-1.67%25%20of%20one%20core-brightgreen)](#performance)
[![Memory](https://img.shields.io/badge/memory-19MB-brightgreen)](#performance)

<img src="docs/screenshots/menubar.png" alt="miniStat in the macOS menu bar" width="900">

[中文说明](README.md) · [Download](https://github.com/waterliu1981/miniStat/releases) · [Report an issue](https://github.com/waterliu1981/miniStat/issues)

</div>

---

## Why miniStat?

Most system monitors are powerful and heavy — dozens of charts, background daemons, login items, network reporting, root helpers.

miniStat goes the other way. It answers one question at a glance:

> *Is my Mac running hot? Is the GPU busy? Am I low on memory? Is the disk filling up?*

Then it stays quietly out of your way.

| | |
|---|---|
| **One glance** | Two lines: label on top, value below. No hovering, no opening menus. |
| **Featherweight** | **184 KB** app bundle, **19 MB** RAM, **1.67% of one core**. |
| **No daemon, no root** | A plain user-space app (`LSUIElement`). No helper processes, no privileged installs. |
| **No network** | Not a single connection. Everything is read locally. |
| **Delete = gone** | No system files touched. Drag it to the Trash and it's completely removed. |
| **Looks right** | Pixel-aligned to the menu bar. Numbers don't jump or wobble. |

---

## What it shows

```
 CPU   GPU   MEM   SSD
 34°   13%   51%   77%
```

| Metric | Meaning | Source |
|---|---|---|
| **CPU** | CPU temperature (°C) | Apple Silicon HID temperature sensors (`tdie` / `tcal` average) |
| **GPU** | GPU utilization (%) | `AGXAccelerator` via `ioreg` |
| **MEM** | Memory usage (%) | `host_statistics64` — same as Activity Monitor |
| **SSD** | Disk usage (%) | `URLResourceValues` — same as Finder |

Using the official data sources means the numbers **agree with Activity Monitor and Finder**, so you're not reconciling two different opinions about the same machine.

---

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```bash
# One command: build → deploy → register a login agent
git clone https://github.com/waterliu1981/miniStat
cd miniStat && bash install.sh
```

It shows up in your menu bar immediately. The app lands in `~/Applications` and is registered as a login item.

**Verify it's running:**

```bash
pgrep -x miniStat
defaults read ~/Applications/miniStat.app/Contents/Info.plist CFBundleShortVersionString
```

**Uninstall** — completely clean, no leftovers:

```bash
launchctl bootout gui/$(id -u)/local.waterliu.ministat
rm -rf ~/Applications/miniStat.app
rm ~/Library/LaunchAgents/local.waterliu.ministat.plist
```

---

## Performance

Measured on **M4 MacBook Air, 10 cores, two external 4K displays (non-mirrored), 2-second refresh:**

| | miniStat v1.1.1+ |
|---|---|
| CPU | **1.67% of one core** (0.167% of the whole machine) |
| Memory | **19 MB** |
| App bundle | **184 KB** |
| Processes | **1** (no helpers) |
| Background daemons | **0** |

For comparison, the same app built on `NSStatusItem` subviews (the v1.1 approach) consumed **50.9% of a core** — a 30× difference. The whole reason is explained in [how it works](#how-it-works), and it's a genuinely interesting macOS pitfall.

---

## How it works

### The trap: custom views in the menu bar are software-rasterized on every refresh

The obvious way to build a two-line menu bar item is a stack of `NSTextField`s inside the status item's button. It works — but AppKit reacts to *any* `NSStatusItem` with custom subviews by re-rendering the whole item **on the CPU** every time it's marked dirty:

```
_updateReplicants
 └ _redrawReplicantSnapshot:
   └ _cacheDisplayInRect:toBitmapImageRep:
     └ CALayer renderInContext          ← software rasterization
       └ CTFontTransformGlyphs / CTFontDrawGlyphs
```

This path doesn't care whether your text actually changed. A 2-second timer gets amplified into **thousands of redraws per second**. With two external 4K displays, that's a permanent half-core.

**The fix:** drop the subviews entirely and use `button.attributedTitle`. AppKit handles it as a lightweight text swap and never enters the snapshot path.

### Making two lines align without subviews

With `attributedTitle`, both rows must share the *same cell grid*, or the upper row shifts whenever a value changes width.

- **Cell width** = `max(widest label, widest value shape) + padding`
- **Separators** use the *value font's* space in both rows (otherwise the rows differ by several points)
- **Intra-cell padding** uses multiple whitespace widths: `U+2003`, `U+2002`, `U+2009`, `U+200A`
- The padding constant `4.78` is not arbitrary — it was **brute-forced across all values 0–99** to minimize alignment error (the two fonts have different hair-space widths: 0.706pt vs 0.820pt)

Result: maximum misalignment **0.28pt** — less than one physical pixel on a Retina display.

> Two dead ends worth knowing: `.kern` gets **multiplied by the run's character count** in CoreText, and consecutive spaces get **compressed**. Neither can be used for fixed-width layout.

### Why `baselineOffset = -4`

`NSStatusBarButton`'s `titleRect(forBounds:)` returns **`(0, 14, w, 16)`** — the button is 22pt tall, but the system gives the title only **16pt**, sitting in the lower portion. Two lines are ~20pt naturally, so AppKit clips them **to the top edge**, dumping all the slack at the bottom.

Line-height parameters (`minimumLineHeight` / `maximumLineHeight`) only change *how much* is clipped — they can't move the block down. The only working lever is `.baselineOffset`.

| baselineOffset | Top gap | Bottom gap |
|---|---|---|
| -2.0 | 10px | 17px |
| -3.75 | 14px | 13px |
| **-4.0** | **14px** | **13px** |
| -4.25 | 15px | 12px |

Final value: **-4.0** — a 1px (0.5pt) difference, the smallest unit at 2× scale.

### How the CPU temperature is actually read

On Apple Silicon, `AppleSMC` has moved to the RTBuddy/SOCD architecture — ordinary processes can open the `IOService` successfully but **read no keys at all**.

miniStat uses the same path iStat Menus does: IOKit's private HID event system, matching `PrimaryUsagePage=0xff00` / `PrimaryUsage=5`, resolving `IOHIDEventSystemClient*` symbols via `dlsym`. **No root required.**

Two sharp edges, documented in `Sensors.swift`:

1. `IOHIDEventSystemClientSetMatching` returns `Void`, not `Int32` — the wrong signature means a segfault.
2. The client must be **retained** — service references are only valid while the client is alive; releasing it and touching a service gives you `SIGBUS`.

### The SSD percentage trap

**Don't use `df /`** — on macOS `/` is a read-only system volume and reports a bogus ~19%. Use `/System/Volumes/Data`, or `URLResourceValues` (what Finder uses, and what miniStat uses).

---

## Customization

Right-click the menu bar item:

- **⌘1 – ⌘4** — toggle each metric
- **Font size** — Small / Standard / Large
- **Refresh interval** — 1 / 2 / 3 / 5 / 10 seconds (default 2s)

Hover for a tooltip with one-decimal values and the number of temperature sensors found.

---

## FAQ

**Does it need root?**
No. Everything runs in user space.

**Does it phone home?**
No. It makes no network connections of any kind.

**Will it work on Intel Macs?**
The GPU and temperature paths are Apple Silicon specific. Intel isn't supported yet.

**Why is 100% shown as 99%?**
Fixed-width values keep the menu bar from reflowing. Capping at two digits keeps every value the same width.

**Can I run it alongside iStat Menus?**
Technically yes, but you'd be reading the same sensors twice. There's a `disable-istat-daemon.sh` helper in the repo if you're switching over.

---

## Building from source

```bash
./build.sh                    # compile → bundle → ad-hoc sign → deploy
SKIP_TAG_CHECK=1 ./build.sh   # skip the tag check for local experiments
```

Only needs the system `swiftc`. No third-party packages, no network.

Release flow:

```bash
git checkout main && git merge --no-ff <branch>
git tag -a v1.2.0 -m "v1.2.0 — notes"
./build.sh                     # HEAD must carry a tag or the build is refused
git push origin main && git push origin v1.2.0
```

---

## Version history

| Version | Highlights |
|---|---|
| **v1.1.2** | `build.sh` refuses to build without a tag on `HEAD` — prevents shipping a stale version number |
| **v1.1.1** | **Performance rewrite**: `attributedTitle` instead of subviews → 50.9% → **1.67%** of one core. **Vertical centering fix** (`titleRect` is only 16pt; `baselineOffset = -4`). Fixed `statusItem.length`, 2s refresh with tolerance, tooltip de-duplication |
| v1.1 | Incremental refresh; fixed-width cells so values stop jittering; tighter column spacing |
| v1.0 | First release: CPU temperature / GPU / memory / SSD, no root |

---

## License

[MIT](LICENSE)

---

<div align="center">

**Built for people who want to know — without being interrupted.**

If miniStat saves you a few menu-bar clicks, [a star](https://github.com/waterliu1981/miniStat) is appreciated.

</div>
