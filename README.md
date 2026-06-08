# video2live

Turn a slice of a video into an Apple **Live Photo** on macOS. Pick the segment by
dragging a fixed-length window over the timeline; export a single `.pvt` package that you
just drag into **Photos** — no special permissions required.

*中文说明见下方 ↓*

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

---

## English

### What it does
- Open (or drag-and-drop) any video.
- Scrub a **draggable, fixed-length window** over a thumbnail timeline to choose the clip.
- Live Photo length is **fixed at 3 seconds** (the key photo is the middle frame).
- Exports a `.pvt` package — a bundle that shows up as **a single file** in Finder.
- Double-click the `.pvt` (or drag it into **Photos**) and it imports as one Live Photo.
  **No Photos-library permission needed.**

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
2. Drag the **yellow window** on the timeline to pick the 3-second clip (use **Preview
   selection** to check).
3. Choose an export folder (defaults to `~/Pictures/video2live`).
4. Click **Create & reveal in Finder**.
5. In Finder, **double-click the `.pvt`** (or drag it into Photos) → it becomes a Live Photo.

### Language
The UI is **bilingual**: it shows English or Chinese automatically based on your macOS
system language.

### Customizing the duration
Edit the single constant at the top of
[`Sources/LiveConverter/LiveConverterApp.swift`](Sources/LiveConverter/LiveConverterApp.swift):
```swift
let kLivePhotoDuration: Double = 3.0   // seconds
```
Then rebuild.

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
| `Sources/LiveConverter/LivePhotoGenerator.swift` | Trim, key frame, paired metadata, `.pvt` |
| `Sources/LiveConverter/Localization.swift` | English/Chinese string helper |
| `build.sh` / `make_dmg.sh` | Build the `.app` / build the `.dmg` |

### License
[MIT](LICENSE) © 2026 szhan311

---

## 中文

### 功能
- 打开(或拖拽)任意视频。
- 在缩略图时间轴上拖动一个**固定长度的窗口**来选取片段。
- Live Photo 时长**固定为 3 秒**(封面取片段中点那一帧)。
- 导出一个 `.pvt` 包 —— 在 Finder 里显示为**单个文件**。
- 双击 `.pvt`(或把它拖进**「照片」**)即可作为一张 Live Photo 导入,**无需任何权限**。

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
2. 拖动时间轴上的**黄色窗口**选取 3 秒片段(可点 **预览选中片段** 查看)。
3. 选择导出文件夹(默认 `~/Pictures/video2live`)。
4. 点 **生成并在访达中显示**。
5. 在访达里**双击 `.pvt`**(或拖进「照片」)→ 即成为一张 Live Photo。

### 语言
界面**中英双语**,会根据 macOS 系统语言自动显示中文或英文。

### 自定义时长
修改 [`Sources/LiveConverter/LiveConverterApp.swift`](Sources/LiveConverter/LiveConverterApp.swift)
顶部那一行常量:
```swift
let kLivePhotoDuration: Double = 3.0   // 秒
```
然后重新构建。

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
| `Sources/LiveConverter/LivePhotoGenerator.swift` | 截取、关键帧、配对元数据、`.pvt` |
| `Sources/LiveConverter/Localization.swift` | 中英文字符串助手 |
| `build.sh` / `make_dmg.sh` | 构建 `.app` / 构建 `.dmg` |

### 许可证
[MIT](LICENSE) © 2026 szhan311
