import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

private enum WorkMode: String {
    case single
    case threeUp
}

private enum ColorSection: String {
    case basics
    case wheels
    case warper
}

struct ContentView: View {
    @StateObject private var model = VideoModel()
    @StateObject private var collageModel = CollageModel()
    @State private var isGenerating = false
    @State private var isDropTargeted = false
    @State private var workMode: WorkMode = .single
    @State private var colorGrade = ColorGrade.neutral
    @State private var colorPreset = ColorGrade.Preset.original
    @State private var isColorExpanded = false
    @State private var colorSection: ColorSection = .basics
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
            modePicker

            if workMode == .single {
                singleEditor
            } else {
                threeUpEditor
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
                    Label(workMode == .single
                          ? L.t("Create & reveal in Finder", "生成并在访达中显示")
                          : L.t("Create three-up & reveal", "生成三拼并显示"),
                          systemImage: "livephoto")
                        .frame(minWidth: 180)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canGenerate)
            }

            statusBar
        }
        .padding(18)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onChange(of: langPref) { _ in
            // Re-localize the idle greeting immediately (other labels re-render on their own).
            if workMode == .single && model.asset == nil && !model.isBusy && !isGenerating {
                model.status = L.t("Open a video file to begin.", "请打开一个视频文件开始。")
            } else if workMode == .threeUp && collageModel.clips.isEmpty && !collageModel.isBusy && !isGenerating {
                collageModel.status = L.t("Choose three videos to build a three-up Live Photo.",
                                          "选择三个视频，生成三拼 Live Photo。")
            }
        }
        .onChange(of: colorGrade) { grade in
            model.setColorGrade(grade)
            collageModel.setColorGrade(grade)
        }
    }

    private var header: some View {
        HStack {
            Button {
                workMode == .single ? openVideo() : openThreeVideos()
            } label: {
                Label(workMode == .single
                      ? L.t("Open Video…", "打开视频…")
                      : L.t("Open 3 Videos…", "打开 3 个视频…"),
                      systemImage: "folder")
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

    private var canGenerate: Bool {
        guard !isGenerating && !model.isBusy && !collageModel.isBusy else { return false }
        switch workMode {
        case .single:
            return model.asset != nil
        case .threeUp:
            return collageModel.canGenerate
                && collageModel.outputDuration(targetDuration: model.targetDuration) > 0
        }
    }

    private var modePicker: some View {
        Picker(selection: $workMode) {
            Text(L.t("Single video", "单视频")).tag(WorkMode.single)
            Text(L.t("Three-up", "三拼")).tag(WorkMode.threeUp)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
    }

    private var singleEditor: some View {
        HStack(alignment: .top, spacing: 14) {
            singleMediaPanel
                .frame(maxWidth: .infinity, alignment: .top)

            colorSidePanel
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var singleMediaPanel: some View {
        VStack(spacing: 10) {
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
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
            )

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
                Text(L.t("Drag the yellow box to choose the clip; drag the white 📷 marker to pick the key photo frame.",
                         "拖黄色框选片段；拖白色 📷 标记选封面帧。"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var threeUpEditor: some View {
        HStack(alignment: .top, spacing: 14) {
            threeUpMediaPanel
                .frame(maxWidth: .infinity, alignment: .top)

            colorSidePanel
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var threeUpMediaPanel: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        threeUpSlot(index)
                    }
                }
                .frame(width: 172)

                threeUpSelectedControls
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            HStack {
                Text(threeUpRangeLabel)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
                Button {
                    openThreeVideos()
                } label: {
                    Label(L.t("Choose 3 videos", "选择 3 个视频"), systemImage: "film")
                }
                Button {
                    collageModel.clear()
                } label: {
                    Label(L.t("Clear", "清空"), systemImage: "trash")
                }
                .disabled(collageModel.clips.isEmpty)
            }

            Text(L.t("Stacks three videos vertically into one Live Photo. Each clip has its own start time; the key photo is picked from the final combined video.",
                     "把三个视频竖向拼成一张 Live Photo。点选上方素材后，在下方调整这一段的视频区间、预览和声音；封面帧从最终合成视频中选取。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func threeUpSlot(_ index: Int) -> some View {
        let isSelected = collageModel.clips.indices.contains(index)
            && collageModel.selectedClipID == collageModel.clips[index].id

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.15))

            if index < collageModel.clips.count {
                let clip = collageModel.clips[index]
                HStack(spacing: 8) {
                    Group {
                        if let thumbnail = clip.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .clipped()

                    VStack(alignment: .leading, spacing: 5) {
                        Text(L.t("Clip \(index + 1)", "素材 \(index + 1)"))
                            .font(.caption.weight(.semibold))
                        Text(clip.url.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f s", clip.duration))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Image(systemName: clip.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(clip.audioEnabled ? Color.accentColor : Color.secondary)
                                .help(clip.audioEnabled
                                      ? L.t("Sound kept for this clip", "这个素材会保留声音")
                                      : L.t("Sound muted for this clip", "这个素材会静音"))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)

                Button {
                    collageModel.remove(clip)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white, .black.opacity(0.7))
                .padding(6)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.t("Clip \(index + 1)", "素材 \(index + 1)"))
                            .font(.caption.weight(.semibold))
                        Text(L.t("Choose video", "选择视频"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .frame(height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.25),
                              lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if collageModel.clips.indices.contains(index) {
                collageModel.select(index: index)
            } else {
                openThreeVideos()
            }
        }
    }

    private var threeUpSelectedControls: some View {
        VStack(spacing: 10) {
            if let index = collageModel.selectedIndex, collageModel.clips.indices.contains(index) {
                let clip = collageModel.clips[index]
                let outputDuration = collageModel.outputDuration(targetDuration: model.targetDuration)
                let maxStart = collageModel.maxStart(for: index, targetDuration: model.targetDuration)
                let canAdjustStart = maxStart.isFinite && maxStart > 0.000001

                ZStack {
                    VideoPlayer(player: collageModel.player)
                        .background(Color.black)
                    if outputDuration <= 0 {
                        Color.black.opacity(0.45)
                        Text(L.t("Selected range is too short", "选中区间太短"))
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 154)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Label(L.t("Clip \(index + 1)", "素材 \(index + 1)"),
                          systemImage: "film")
                        .font(.callout.weight(.semibold))
                    Text(clip.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Toggle(isOn: Binding(
                        get: {
                            collageModel.clips.indices.contains(index)
                                ? collageModel.clips[index].audioEnabled
                                : false
                        },
                        set: { collageModel.setAudioEnabled($0, for: index) }
                    )) {
                        Label(L.t("Keep sound", "保留声音"),
                              systemImage: clip.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    .help(L.t("Include this clip's audio in the exported three-up video.",
                              "导出三拼视频时是否保留这个素材的声音。"))
                }

                HStack(spacing: 8) {
                    Text(L.t("Range", "区间"))
                        .font(.caption)
                        .frame(width: 42, alignment: .leading)
                    if canAdjustStart {
                        Slider(
                            value: Binding(
                                get: {
                                    guard collageModel.clips.indices.contains(index) else { return 0 }
                                    return safeSliderValue(collageModel.clips[index].startSeconds,
                                                           upperBound: maxStart)
                                },
                                set: {
                                    collageModel.setStart($0,
                                                          for: index,
                                                          targetDuration: model.targetDuration)
                                }
                            ),
                            in: 0...maxStart
                        )
                    } else {
                        Slider(value: .constant(0), in: 0...1)
                            .disabled(true)
                    }
                    Text(String(format: "%.1f → %.1f s",
                                clip.startSeconds,
                                clip.startSeconds + outputDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text(String(format: L.t("Source %.1f s, output %.1f s",
                                            "素材 %.1f 秒，输出 %.1f 秒"),
                                clip.duration,
                                outputDuration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button {
                        collageModel.previewSelected(targetDuration: model.targetDuration)
                    } label: {
                        Label(L.t("Preview clip", "预览素材"), systemImage: "play.fill")
                    }
                    .disabled(outputDuration <= 0)
                }

                if collageModel.clips.count == 3 {
                    threeUpKeyPhotoControls(outputDuration: outputDuration)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(L.t("Choose or drop videos, then click a clip above to edit it.",
                             "选择或拖入视频后，点击左侧素材即可编辑。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minHeight: 238)
            }
        }
    }

    private func threeUpKeyPhotoControls(outputDuration: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
            Text(L.t("Key photo", "封面帧"))
                .font(.caption)
                .frame(width: 76, alignment: .leading)
            Slider(
                value: Binding(get: { collageModel.keyPhotoFraction },
                               set: { collageModel.setKeyPhotoFraction($0) }),
                in: 0...1,
                step: 0.01
            )
            .disabled(outputDuration <= 0)
            Text(String(format: "%.2f s", collageModel.keyPhotoSeconds(outputDuration: outputDuration)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func safeSliderValue(_ value: Double, upperBound: Double) -> Double {
        guard value.isFinite, upperBound.isFinite else { return 0 }
        return min(max(0, value), upperBound)
    }

    private var durationSlider: some View {
        HStack(spacing: 10) {
            Text(L.t("Length", "时长")).font(.callout)
            Slider(
                value: Binding(get: { model.targetDuration },
                               set: {
                                   model.setTargetDuration($0)
                                   if workMode == .threeUp {
                                       collageModel.clampStarts(targetDuration: model.targetDuration)
                                   }
                               }),
                in: VideoModel.minDuration...VideoModel.maxDuration,
                step: 0.5,
                onEditingChanged: { editing in
                    if !editing && workMode == .single { model.refreshCover() }
                }
            )
            Text(String(format: "%.1f s", model.targetDuration))
                .font(.callout).monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var colorSidePanel: some View {
        VStack(spacing: 12) {
            durationSlider
            colorGradePanel
        }
    }

    private var colorGradePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    isColorExpanded.toggle()
                } label: {
                    Image(systemName: isColorExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(isColorExpanded
                      ? L.t("Hide fine adjustments", "收起精细调节")
                      : L.t("Show fine adjustments", "展开精细调节"))

                Label(L.t("Color", "调色"), systemImage: "camera.filters")
                    .font(.callout.weight(.semibold))

                Picker(selection: colorPresetSelection) {
                    ForEach(ColorGrade.Preset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                } label: {
                    Text(L.t("Preset", "预设"))
                }
                .pickerStyle(.menu)
                .frame(width: 132)
                .help(L.t("Choose a color preset.", "选择调色预设。"))

                Spacer()

                Button {
                    resetColorGrade()
                } label: {
                    Label(L.t("Reset", "重置"), systemImage: "arrow.counterclockwise")
                }
                .disabled(colorGrade.isNeutral && colorPreset == .original)
            }

            if isColorExpanded {
                Picker(selection: $colorSection) {
                    Text(L.t("Basics", "基础")).tag(ColorSection.basics)
                    Text(L.t("Wheels", "色轮")).tag(ColorSection.wheels)
                    Text("Warper").tag(ColorSection.warper)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)

                activeColorControls
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.12), value: isColorExpanded)
    }

    private var colorGradeColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 260), spacing: 8)
        ]
    }

    @ViewBuilder
    private var activeColorControls: some View {
        switch colorSection {
        case .basics:
            basicColorControls
        case .wheels:
            colorWheelControls
        case .warper:
            warperControls
        }
    }

    private var basicColorControls: some View {
        LazyVGrid(columns: colorGradeColumns, alignment: .leading, spacing: 8) {
            colorGradeControl(L.t("Exposure", "曝光"),
                              systemImage: "sun.max",
                              keyPath: \.exposure,
                              range: -1...1,
                              step: 0.05,
                              defaultValue: 0,
                              valueText: String(format: "%+.2f", colorGrade.exposure))
            colorGradeControl(L.t("Contrast", "对比度"),
                              systemImage: "circle.lefthalf.filled",
                              keyPath: \.contrast,
                              range: 0.5...1.8,
                              step: 0.05,
                              defaultValue: 1,
                              valueText: String(format: "%.0f%%", colorGrade.contrast * 100))
            colorGradeControl(L.t("Saturation", "饱和度"),
                              systemImage: "drop.fill",
                              keyPath: \.saturation,
                              range: 0...2,
                              step: 0.05,
                              defaultValue: 1,
                              valueText: String(format: "%.0f%%", colorGrade.saturation * 100))
            colorGradeControl(L.t("Warmth", "色温"),
                              systemImage: "thermometer.sun.fill",
                              keyPath: \.warmth,
                              range: -1...1,
                              step: 0.05,
                              defaultValue: 0,
                              valueText: String(format: "%+.0f", colorGrade.warmth * 100))
            colorGradeControl(L.t("Tint", "色调"),
                              systemImage: "eyedropper.halffull",
                              keyPath: \.tint,
                              range: -1...1,
                              step: 0.05,
                              defaultValue: 0,
                              valueText: String(format: "%+.0f", colorGrade.tint * 100))
            colorGradeControl(L.t("Vignette", "暗角"),
                              systemImage: "circle.dotted",
                              keyPath: \.vignette,
                              range: 0...0.8,
                              step: 0.05,
                              defaultValue: 0,
                              valueText: String(format: "%.0f%%", colorGrade.vignette * 100))
        }
    }

    private var colorWheelControls: some View {
        HStack(alignment: .top, spacing: 14) {
            ColorWheelPad(title: L.t("Shadows", "暗部"),
                          wheel: colorWheelBinding(\.shadows))
            ColorWheelPad(title: L.t("Midtones", "中间调"),
                          wheel: colorWheelBinding(\.midtones))
            ColorWheelPad(title: L.t("Highlights", "高光"),
                          wheel: colorWheelBinding(\.highlights))
        }
    }

    private var warperControls: some View {
        ColorWarperPad(warper: warperBinding)
            .frame(minHeight: 210)
    }

    private var colorPresetSelection: Binding<ColorGrade.Preset> {
        Binding(
            get: { colorPreset },
            set: { preset in
                colorPreset = preset
                if preset != .custom {
                    colorGrade = preset.grade
                } else {
                    isColorExpanded = true
                }
            }
        )
    }

    private func colorGradeControl(_ title: String,
                                   systemImage: String,
                                   keyPath: WritableKeyPath<ColorGrade, Double>,
                                   range: ClosedRange<Double>,
                                   step: Double,
                                   defaultValue: Double,
                                   valueText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .frame(width: 48, alignment: .leading)
            Slider(value: colorGradeBinding(keyPath), in: range, step: step)
            Text(valueText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            var next = colorGrade
            next[keyPath: keyPath] = defaultValue
            setCustomColorGrade(next)
        }
        .help(L.t("Double-click to reset this adjustment.",
                  "双击恢复此项默认值。"))
    }

    private func colorGradeBinding(_ keyPath: WritableKeyPath<ColorGrade, Double>) -> Binding<Double> {
        Binding(
            get: { colorGrade[keyPath: keyPath] },
            set: { value in
                var next = colorGrade
                next[keyPath: keyPath] = value
                setCustomColorGrade(next)
            }
        )
    }

    private func colorWheelBinding(_ keyPath: WritableKeyPath<ColorGrade, ColorGrade.ColorWheel>)
    -> Binding<ColorGrade.ColorWheel> {
        Binding(
            get: { colorGrade[keyPath: keyPath] },
            set: { value in
                var next = colorGrade
                next[keyPath: keyPath] = value
                setCustomColorGrade(next)
            }
        )
    }

    private var warperBinding: Binding<ColorGrade.ColorWarper> {
        Binding(
            get: { colorGrade.warper },
            set: { value in
                var next = colorGrade
                next.warper = value
                setCustomColorGrade(next)
            }
        )
    }

    private func setCustomColorGrade(_ next: ColorGrade) {
        colorGrade = next
        colorPreset = next.isNeutral ? .original : .custom
    }

    private func resetColorGrade() {
        colorPreset = .original
        colorGrade = .neutral
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if isGenerating || model.isBusy || collageModel.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(workMode == .single ? model.status : collageModel.status)
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

    private var threeUpRangeLabel: String {
        guard collageModel.clips.count == 3 else {
            return L.t("Three-up: \(collageModel.clips.count)/3 clips loaded",
                       "三拼：已载入 \(collageModel.clips.count)/3 个素材")
        }
        let duration = collageModel.outputDuration(targetDuration: model.targetDuration)
        let keyPhoto = collageModel.keyPhotoSeconds(outputDuration: duration)
        return L.t(String(format: "Three-up: %.2f s (key photo %.2f s)", duration, keyPhoto),
                   String(format: "三拼：%.2f 秒（封面 %.2f 秒）", duration, keyPhoto))
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.enumerated().filter {
            $0.element.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let mode = workMode
        let group = DispatchGroup()
        let urlLock = NSLock()
        var urls = Array<URL?>(repeating: nil, count: providers.count)

        for (index, provider) in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let u = item as? URL { url = u }
                else if let u = item as? NSURL { url = u as URL }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                if let url, Self.isVideoFile(url) {
                    urlLock.lock()
                    urls[index] = url
                    urlLock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let videoURLs = urls.compactMap { $0 }
            guard !videoURLs.isEmpty else { return }
            switch mode {
            case .single:
                model.load(url: videoURLs[0])
            case .threeUp:
                collageModel.add(urls: videoURLs)
            }
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

    private func openThreeVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L.t("Choose exactly three videos for the three-up Live Photo.",
                            "请选择三个视频用于三拼 Live Photo。")
        if panel.runModal() == .OK {
            collageModel.replace(with: Array(panel.urls.prefix(3)))
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
        switch workMode {
        case .single:
            generateSingle()
        case .threeUp:
            generateThreeUp()
        }
    }

    private func generateSingle() {
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
            colorGrade: colorGrade,
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

    private func generateThreeUp() {
        guard collageModel.clips.count == 3 else { return }
        let duration = collageModel.outputDuration(targetDuration: model.targetDuration)
        guard duration > 0 else { return }

        isGenerating = true
        collageModel.status = L.t("Creating three-up Live Photo (.pvt)…",
                                  "正在生成三拼 Live Photo（.pvt）…")

        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let assets = collageModel.clips.map(\.asset)
        let keyPhotoSeconds = collageModel.keyPhotoSeconds(outputDuration: duration)

        LivePhotoGenerator.generateThreeUp(
            assets: assets,
            startSeconds: collageModel.startSeconds,
            durationSeconds: duration,
            coverSeconds: keyPhotoSeconds,
            audioEnabled: collageModel.audioEnabled,
            colorGrade: colorGrade,
            outputDirectory: dir,
            format: .pvt
        ) { result in
            isGenerating = false
            switch result {
            case .failure(let err):
                collageModel.status = L.t("Failed: \(err.localizedDescription)",
                                          "失败：\(err.localizedDescription)")
            case .success(let out):
                NSWorkspace.shared.activateFileViewerSelecting(out.revealURLs)
                collageModel.status = L.t("✅ Exported a three-up .pvt package to \(dir.path). It's selected in Finder.",
                                          "✅ 已导出三拼 .pvt 包到 \(dir.path)，访达里已选中它。")
            }
        }
    }
}
