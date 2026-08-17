# video2live

Turn a slice of a video into an Apple **Live Photo** on macOS. Pick the segment by
dragging a window over the timeline; export a single `.pvt` package that you drag into
**Photos** — or **AirDrop straight to your iPhone**. No special permissions required.

*中文说明见下方 ↓*

[![Download](https://img.shields.io/badge/⬇%20Download%20%2F%20下载-video2live.dmg-brightgreen?style=for-the-badge)](https://github.com/szhan311/video2live/releases/latest/download/video2live.dmg)
&nbsp;
[![Release](https://img.shields.io/github/v/release/szhan311/video2live)](https://github.com/szhan311/video2live/releases/latest)
![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

> **[⬇ Download the latest DMG / 下载最新版 DMG](https://github.com/szhan311/video2live/releases/latest/download/video2live.dmg)** — open it and drag **video2live.app** into Applications. 打开后把 **video2live.app** 拖进「应用程序」即可。

---

## English

### What it does
- Open (or drag-and-drop) any video.
- Or switch to **Three-up** mode, choose three videos, and stack them into one vertical
  Live Photo.
- Scrub a **draggable window** over a thumbnail timeline to choose the clip.
- Live Photo length is **adjustable from 1 to 10 seconds** (default 3s; key photo = middle frame).
- Apply common **color presets** and pro-style controls: basic corrections, shadows /
  midtones / highlights color wheels, and a DaVinci-style hue/sat color warper before
  export.
- For HDR source videos, writes the key photo HEIC with an **ISO/HDR gain map** on
  supported macOS versions so the still frame can display as HDR too.
- Exports a `.pvt` package — a bundle that shows up as **a single file** in Finder.
- Drag the `.pvt` into **Photos**, **or AirDrop it to your iPhone** — either way it becomes
  one Live Photo. **No Photos-library permission needed.**
- Preserves the source video's **date, GPS location and camera make/model**, and keeps
  **portrait videos at the correct aspect ratio**.

### Why `.pvt`?
A Live Photo is fundamentally a **pair**: a still (HEIC) + a video (MOV) linked by a shared
*content identifier*. There is no single standard file that Photos recognizes as a Live
Photo. The `.pvt` package (the same format used by
[RhetTbull/makelive](https://github.com/RhetTbull/makelive)) wraps the pair plus a
`metadata.plist` into one Finder item that macOS Photos imports directly — sidestepping the
PhotoKit permission flow entirely.

### Requirements
- macOS 13+
- Swift toolchain (Xcode **or** just the Command Line Tools: `xcode-select --install`)

### Build & run
```bash
./build.sh            # compile + package video2live.app (ad-hoc signed)
open video2live.app

./make_dmg.sh         # build the app and wrap it in video2live.dmg
```
Or for development: `swift build -c release`.

### How to use
1. Click **Open Video…** or drag a video onto the window.
2. Set the clip length with the **Length** slider (1–10 s), then drag the **yellow window**
   on the timeline to pick the clip (use **Preview selection** to check).
3. Use the **Color** panel for presets, basic adjustment, color wheels, or warper.
4. Choose an export folder (defaults to `~/Pictures/video2live`).
5. Click **Create & reveal in Finder**.
6. In Finder, **drag the `.pvt` into Photos**, or **AirDrop it to your iPhone** → it becomes
   a Live Photo.

### Three-up mode
1. Switch the mode selector from **Single video** to **Three-up**.
2. Click **Open 3 Videos…**, or drag three videos into the window.
3. Set the length with the same **Length** slider. The output is capped by the shortest
   selected clip.
4. Click a clip, then use the lower panel to set that clip's range, preview it, and choose
   whether to keep its sound.
5. Pick the global **key photo** time from the final combined video.
6. Click **Create three-up & reveal** to export one vertical `.pvt` Live Photo.

### Language
The UI is **bilingual** (English / Chinese). Use the **globe menu** at the top-right to pick
**Auto / English / 中文**; *Auto* follows your macOS system language. The choice is remembered.

### Duration
The length is **adjustable in-app** with the **Length** slider (1–10 s) and is remembered
between launches. The default (first run) is the constant at the top of
[`Sources/LiveConverter/LiveConverterApp.swift`](Sources/LiveConverter/LiveConverterApp.swift):
```swift
let kLivePhotoDuration: Double = 3.0   // first-run default, in seconds
```

### How it works
- **Still (HEIC):** the Apple maker note key `"17"` is set to an asset-identifier UUID.
- **Video (MOV):** carries the QuickTime metadata `com.apple.quicktime.content.identifier`
  (same UUID) plus a `com.apple.quicktime.still-image-time` metadata track marking the key
  frame. The selected segment is re-encoded (H.264 + AAC) so it starts on a clean keyframe.
- **`.pvt`:** a package directory containing the HEIC, the MOV, and a `metadata.plist`
  (`PFVideoComplementMetadataVersionKey = 1`).

### Note on signing
The app is **ad-hoc signed** (no Apple Developer ID / notarization). If you share the DMG,
the recipient may need to **right-click → Open** the first time, or allow it under
*System Settings ▸ Privacy & Security*.

### Project layout
| Path | Purpose |
|------|---------|
| `Sources/LiveConverter/LiveConverterApp.swift` | App entry + fixed-duration constant |
| `Sources/LiveConverter/ContentView.swift` | Main UI, open/generate/reveal flow |
| `Sources/LiveConverter/TimelineView.swift` | Thumbnail timeline + draggable window |
| `Sources/LiveConverter/VideoModel.swift` | Video loading, thumbnails, selection, preview |
| `Sources/LiveConverter/ColorGrade.swift` | Color presets, wheels, warper and Core Image pipeline |
| `Sources/LiveConverter/ColorControlViews.swift` | Color wheel and warper controls |
| `Sources/LiveConverter/LivePhotoGenerator.swift` | Trim, key frame, paired metadata, `.pvt` |
| `Sources/LiveConverter/Localization.swift` | English/Chinese string helper |
| `build.sh` / `make_dmg.sh` | Build the `.app` / build the `.dmg` |

### License
[MIT](LICENSE) © 2026 szhan311

---

## 中文

### 功能
- 打开(或拖拽)任意视频。
- 也可以切到**三拼**模式,选择三个视频,竖向拼成一张 Live Photo。
- 在缩略图时间轴上拖动一个**窗口**来选取片段。
- Live Photo 时长**可在 1–10 秒之间调节**(默认 3 秒;封面取片段中点那一帧)。
- 支持常用**调色预设**和偏专业的调色方式:基础校正、暗部/中间调/高光色轮,以及类似达芬奇的 hue/sat Color Warper。
- HDR 源视频会在支持的 macOS 上自动把封面 HEIC 写成带 **ISO/HDR Gain Map** 的照片,让静态封面也能呈现 HDR 效果。
- 导出一个 `.pvt` 包 —— 在 Finder 里显示为**单个文件**。
- 把 `.pvt` 拖进**「照片」**,或**直接 AirDrop 到 iPhone** —— 都会得到一张 Live Photo,**无需任何权限**。
- 保留原视频的**拍摄日期、GPS 位置、设备型号**,竖屏视频**比例正确不变形**。

### 为什么用 `.pvt`?
Live Photo 本质上是**一对文件**:静帧(HEIC)+ 视频(MOV),靠相同的「内容标识符」配对。
不存在能被「照片」识别成 Live Photo 的单一标准文件。`.pvt` 包(与
[RhetTbull/makelive](https://github.com/RhetTbull/makelive) 同一格式)把这一对加上一个
`metadata.plist` 装进一个 Finder 项目里,macOS「照片」可直接导入 —— 从而彻底绕开 PhotoKit
的权限流程。

### 环境要求
- macOS 13+
- Swift 工具链(完整 Xcode **或**仅命令行工具:`xcode-select --install`)

### 构建与运行
```bash
./build.sh            # 编译并打包 video2live.app(ad-hoc 签名)
open video2live.app

./make_dmg.sh         # 构建 App 并打包成 video2live.dmg
```
开发时也可:`swift build -c release`。

### 使用步骤
1. 点 **打开视频…** 或把视频拖进窗口。
2. 用 **时长** 滑块设定片段长度(1–10 秒),再拖动时间轴上的**黄色窗口**选取片段(可点 **预览选中片段** 查看)。
3. 如需调整画面,在 **调色** 面板选择预设,或使用基础调节、色轮、warper。
4. 选择导出文件夹(默认 `~/Pictures/video2live`)。
5. 点 **生成并在访达中显示**。
6. 在访达里把 **`.pvt` 拖进「照片」**,或**直接 AirDrop 到 iPhone** → 即成为一张 Live Photo。

### 三拼模式
1. 把模式从 **单视频** 切到 **三拼**。
2. 点 **打开 3 个视频…**,或把三个视频拖进窗口。
3. 用同一个**时长**滑块设置输出长度;实际时长不会超过最短素材。
4. 点击某个素材后,在下方面板设置这个素材的区间、预览片段,并选择是否保留它的声音。
5. 从最终合成视频里选择全局**封面帧**时间。
6. 点 **生成三拼并显示**,导出一个竖向 `.pvt` Live Photo。

### 语言
界面**中英双语**。用右上角的**地球菜单**选择 **自动 / English / 中文**;「自动」跟随 macOS 系统语言。选择会被记住。

### 时长
时长可在**应用内**用 **时长** 滑块调节(1–10 秒),并会记住上次的设置。首次运行的默认值由
[`Sources/LiveConverter/LiveConverterApp.swift`](Sources/LiveConverter/LiveConverterApp.swift)
顶部这行常量决定:
```swift
let kLivePhotoDuration: Double = 3.0   // 首次运行默认值，单位秒
```

### 工作原理
- **静帧(HEIC):** 在 Apple Maker Note 的 `"17"` 键里写入资产标识符(UUID)。
- **视频(MOV):** 写入 QuickTime 元数据 `com.apple.quicktime.content.identifier`(同一 UUID),
  并加入 `com.apple.quicktime.still-image-time` 元数据轨标记关键帧。所选片段会重新编码
  (H.264 + AAC),保证从干净的关键帧开始。
- **`.pvt`:** 一个包目录,内含 HEIC、MOV 和 `metadata.plist`
  (`PFVideoComplementMetadataVersionKey = 1`)。

### 关于签名
本应用为 **ad-hoc 签名**(没有 Apple 开发者账号 / 公证)。若把 DMG 分享给别人,对方首次打开
可能需要**右键 ▸ 打开**,或在**系统设置 ▸ 隐私与安全性**里允许。

### 文件结构
| 路径 | 作用 |
|------|------|
| `Sources/LiveConverter/LiveConverterApp.swift` | 入口 + 固定时长常量 |
| `Sources/LiveConverter/ContentView.swift` | 主界面、打开/生成/显示流程 |
| `Sources/LiveConverter/TimelineView.swift` | 缩略图时间轴 + 可拖动窗口 |
| `Sources/LiveConverter/VideoModel.swift` | 视频加载、缩略图、选择、预览 |
| `Sources/LiveConverter/ColorGrade.swift` | 调色预设、色轮、warper 与 Core Image 管线 |
| `Sources/LiveConverter/ColorControlViews.swift` | 色轮和 warper 控件 |
| `Sources/LiveConverter/LivePhotoGenerator.swift` | 截取、关键帧、配对元数据、`.pvt` |
| `Sources/LiveConverter/Localization.swift` | 中英文字符串助手 |
| `build.sh` / `make_dmg.sh` | 构建 `.app` / 构建 `.dmg` |

### 许可证
[MIT](LICENSE) © 2026 szhan311
