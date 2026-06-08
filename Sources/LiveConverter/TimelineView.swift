import SwiftUI

/// A filmstrip of thumbnails with a draggable, fixed-width selection window.
struct TimelineView: View {
    @ObservedObject var model: VideoModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(model.totalDuration, 0.0001)
            let windowFrac = min(model.windowDuration / total, 1.0)
            let windowWidth = max(width * windowFrac, 24)
            let usable = max(width - windowWidth, 0.0001)
            let startFrac = model.maxStart > 0 ? (model.selectionStart / model.maxStart) : 0
            let xOffset = usable * startFrac

            ZStack(alignment: .leading) {
                // Thumbnail strip
                HStack(spacing: 0) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(max(model.thumbnails.count, 1)),
                                   height: geo.size.height)
                            .clipped()
                    }
                }
                .frame(width: width, height: geo.size.height)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Dimmed areas outside the window
                Color.black.opacity(0.5)
                    .frame(width: xOffset)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Color.black.opacity(0.5)
                    .frame(width: max(width - xOffset - windowWidth, 0))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .offset(x: xOffset + windowWidth)

                // Selection window
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .background(Color.yellow.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 8)))
                    .frame(width: windowWidth, height: geo.size.height)
                    .offset(x: xOffset)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .foregroundColor(.yellow)
                            .offset(x: xOffset + windowWidth / 2 - width / 2),
                        alignment: .center
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard model.maxStart > 0, usable > 0 else { return }
                                // Map drag location to a window start, keeping the window fully inside.
                                let proposedX = min(max(value.location.x - windowWidth / 2, 0), usable)
                                let frac = proposedX / usable
                                model.setStart(frac * model.maxStart)
                            }
                            .onEnded { _ in
                                model.refreshCover()
                            }
                    )
            }
        }
        .frame(height: 88)
        .opacity(model.thumbnails.isEmpty ? 0.3 : 1)
    }
}
