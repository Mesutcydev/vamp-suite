import Foundation
import SwiftUI

@MainActor
final class AnnotationOverlayStore: ObservableObject {
    enum Tool: String, CaseIterable {
        case draw
        case highlight
        case erase

        var title: String {
            switch self {
            case .draw:
                return "Draw"
            case .highlight:
                return "Highlight"
            case .erase:
                return "Erase"
            }
        }

        var icon: String {
            switch self {
            case .draw:
                return "pencil.tip"
            case .highlight:
                return "highlighter"
            case .erase:
                return "eraser"
            }
        }
    }

    struct Stroke: Identifiable, Equatable {
        let id = UUID()
        var tool: Tool
        var points: [CGPoint]
    }

    @Published var isVisible = false
    @Published var selectedTool: Tool = .draw
    @Published private(set) var strokes: [Stroke] = []

    func beginStroke(at point: CGPoint) {
        if selectedTool == .erase {
            erase(near: point)
            return
        }
        strokes.append(Stroke(tool: selectedTool, points: [point]))
    }

    func appendPoint(_ point: CGPoint) {
        guard selectedTool != .erase, !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
    }

    func clear() {
        strokes.removeAll()
    }

    private func erase(near point: CGPoint) {
        let threshold: CGFloat = 28
        strokes.removeAll { stroke in
            stroke.points.contains { candidate in
                abs(candidate.x - point.x) < threshold && abs(candidate.y - point.y) < threshold
            }
        }
    }
}

/// The freehand annotation canvas drawn over the live stream. Lives here alongside its store
/// (it previously sat in the now-removed RemoteDesktopView.swift, but the live MirrorScreen
/// reuses it, so it moved to this already-compiled file rather than being deleted with the
/// dead view).
struct AnnotationCanvasOverlay: View {
    @ObservedObject var store: AnnotationOverlayStore

    var body: some View {
        Canvas { context, _ in
            for stroke in store.strokes {
                guard let first = stroke.points.first else { continue }
                var path = Path()
                path.move(to: first)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point)
                }

                let color: Color
                let width: CGFloat
                switch stroke.tool {
                case .draw:
                    color = .yellow
                    width = 3
                case .highlight:
                    color = .yellow.opacity(0.35)
                    width = 12
                case .erase:
                    color = .clear
                    width = 1
                }

                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero {
                        store.beginStroke(at: value.location)
                    } else {
                        store.appendPoint(value.location)
                    }
                }
        )
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                ForEach(AnnotationOverlayStore.Tool.allCases, id: \.self) { tool in
                    Button {
                        store.selectedTool = tool
                    } label: {
                        Image(systemName: tool.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(
                                (store.selectedTool == tool ? Color.orange : Color.black.opacity(0.55)),
                                in: Circle()
                            )
                    }
                }
                Button("Clear") {
                    store.clear()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .padding(12)
        }
    }
}
