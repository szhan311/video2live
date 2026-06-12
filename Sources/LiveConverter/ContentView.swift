import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = VideoModel()
    @State private var isGenerating = false
    @State private var isDropTargeted = false
    @AppStorage("liveconverter.outputDir") private var outputDirPath = ""
    @AppStorage(L.prefKey) private var langPref = "auto"

    /// Where the paired HEIC + MOV are written. Defaults to ~/Pictures/LiveConverter.
    private var outputDir: URL {
        if !outputDirPath.isEmpty {
            return URL(fileURLWithPath: outputDirPath, isDirectory: true)
        }
        return Self.defaultOutputDir
    }

    static var defaultOutputDir: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return pictures.appendingPathComponent("video2live", isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            // Player + key-photo preview
            HStack(spacing: 12) {
                ZStack {
                    VideoPlayer(player: model.player)
                        .background(Color.black)
                    if model.asset == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text(L.t("Drop a video here, or click “Open Video…”",
                                     "把视频拖到这里，或点「打开视频…」"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                )

                VStack(spacing: 6) {
                    Text(L.t("Key photo", "封面帧")).font(.caption).foregroundStyle(.secondary)
                    Group {
                        if let cover = model.coverPreview {
                            Image(nsImage: cover)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 160, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Live Photo length
            HStack(spacing: 10) {
                Text(L.t("Length", "时长")).font(.callout)
                Slider(
                    value: Binding(get: { model.targetDuration },
                                   set: { model.setTargetDuration($0) }),
                    in: VideoModel.minDuration...VideoModel.maxDuration,
                    step: 0.5,
                    onEditingChanged: { editing in if !editing { model.refreshCover() } }
                )
                Text(String(format: "%.1f s", model.targetDuration))
                    .font(.callout).monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }

            // Timeline + selection
            VStack(spacing: 6) {
                TimelineView(model: model)
                HStack {
                    Text(rangeLabel).font(.callout).monospacedDigit()
                    Spacer()
                    Button {
                        model.previewSegment()
                    } label: {
                        Label(L.t("Preview selection", "预览选中片段"), systemImage: "play.fill")
                    }
                    .disabled(model.asset == nil)
                }
            }

            Divider()

            Text(L.t("Creates a .pvt package (a single file in Finder). Drag it into Mac Photos, or AirDrop it to an iPhone — either way it becomes one Live Photo. No permission needed.",
                     "生成一个 .pvt 包（Finder 里是单个文件）：拖进 Mac「照片」，或直接 AirDrop 到 iPhone——都会合成一张 Live Photo，无需任何权限。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Export folder
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(L.t("Export folder:", "导出文件夹：")).font(.callout)
                Text(outputDir.path)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(outputDir.path)
                Spacer()
                Button(L.t("Change…", "更改…")) { chooseOutputFolder() }
                if !outputDirPath.isEmpty {
                    Button(L.t("Reset", "重置")) { outputDirPath = "" }
                }
            }

            // Action
            HStack {
                Spacer()
                Button {
                    generate()
                } label: {
                    Label(L.t("Create & reveal in Finder", "生成并在访达中显示"), systemImage: "livephoto")
                        .frame(minWidth: 180)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.asset == nil || isGenerating || model.isBusy)
            }

            statusBar
        }
        .padding(18)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onChange(of: langPref) { _ in
            // Re-localize the idle greeting immediately (other labels re-render on their own).
            if model.asset == nil && !model.isBusy && !isGenerating {
                model.status = L.t("Open a video file to begin.", "请打开一个视频文件开始。")
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                openVideo()
            } label: {
                Label(L.t("Open Video…", "打开视频…"), systemImage: "folder")
            }
            Spacer()
            Picker(selection: $langPref) {
                Text(L.t("Auto", "自动（跟随系统）")).tag("auto")
                Text("English").tag("en")
                Text("中文").tag("zh")
            } label: {
                Image(systemName: "globe")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(L.t("Language", "语言"))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if isGenerating || model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeLabel: String {
        guard model.asset != nil else { return L.t("No video loaded", "未载入视频") }
        let s = model.selectionStart
        let e = s + model.windowDuration
        return L.t(String(format: "Clip: %.2f s → %.2f s (key photo %.2f s)", s, e, model.coverTime),
                   String(format: "截取区间：%.2f s → %.2f s（封面 %.2f s）", s, e, model.coverTime))
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            guard let url, Self.isVideoFile(url) else { return }
            DispatchQueue.main.async { model.load(url: url) }
        }
        return true
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .video)
                || type.conforms(to: .audiovisualContent)
        }
        return ["mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg"].contains(url.pathExtension.lowercased())
    }

    // MARK: - Actions

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url: url)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L.t("Choose", "选择")
        panel.directoryURL = outputDir
        if panel.runModal() == .OK, let url = panel.url {
            outputDirPath = url.path
        }
    }

    private func generate() {
        guard let asset = model.asset else { return }
        isGenerating = true
        model.status = L.t("Creating Live Photo (.pvt)…", "正在生成 Live Photo（.pvt）…")

        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        LivePhotoGenerator.generate(
            asset: asset,
            startSeconds: model.selectionStart,
            durationSeconds: model.windowDuration,
            coverSeconds: model.coverTime,
            outputDirectory: dir,
            format: .pvt
        ) { result in
            isGenerating = false
            switch result {
            case .failure(let err):
                model.status = L.t("Failed: \(err.localizedDescription)",
                                   "失败：\(err.localizedDescription)")
            case .success(let out):
                NSWorkspace.shared.activateFileViewerSelecting(out.revealURLs)
                model.status = L.t("✅ Exported a .pvt package to \(dir.path). It's selected in Finder — drag it into Photos, or AirDrop it to your iPhone, to get a Live Photo.",
                                   "✅ 已导出 .pvt 包到 \(dir.path)。访达里已选中它——拖进「照片」，或直接 AirDrop 到 iPhone，即可得到 Live Photo。")
            }
        }
    }
}
