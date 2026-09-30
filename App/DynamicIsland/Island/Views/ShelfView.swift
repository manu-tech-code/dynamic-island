import AppKit
import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// The shelf: opens when you drag something toward the notch, or from the
/// dashboard. Drop to keep, drag out to use, click to select, double-click to open.
struct ShelfView: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let shelf = env.shelf
        let items = shelf.items
        let targets = shelf.selectedOrAll
        VStack(spacing: 0) {
            EarRow(model: model) {
                Image(systemName: "tray.full.fill").foregroundStyle(.teal)
                Text(items.isEmpty ? "Shelf" : "Shelf · \(items.count)")
                if !shelf.selection.isEmpty {
                    Text("\(shelf.selection.count) selected").foregroundStyle(.secondary)
                }
            } trailing: {
                if !items.isEmpty {
                    IslandIconButton(systemName: "airdrop", size: 26, label: "AirDrop \(targets.count == 1 ? "item" : "\(targets.count) items")") {
                        shelf.airDrop(targets)
                    }
                    IslandIconButton(systemName: "square.and.arrow.up", size: 26, label: "Share") {
                        model.presentMenu(shelf.shareMenu(for: targets))
                    }
                    IslandIconButton(systemName: "folder", size: 26, label: "Show in Finder") { shelf.reveal(targets) }
                    IslandIconButton(systemName: "trash", size: 26, label: shelf.selection.isEmpty ? "Clear shelf" : "Remove selected") {
                        withAnimation(.snappy) { shelf.selection.isEmpty ? shelf.clear() : shelf.remove(shelf.selection) }
                    }
                }
            }
            Group {
                if items.isEmpty {
                    DropHint(targeted: model.dropTargeted, large: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(items) { item in ShelfTile(item: item) }
                            DropHint(targeted: model.dropTargeted, large: false)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
    }
}

private struct ShelfTile: View {
    let item: ShelfItemInfo
    @Environment(AppEnvironment.self) private var env
    @State private var hovering = false

    var body: some View {
        let shelf = env.shelf
        let selected = shelf.selection.contains(item.id)
        VStack(spacing: 7) {
            Image(nsImage: shelf.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: item.kind == .image ? 8 : 0, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 88)
        }
        .padding(.vertical, 10)
        .frame(width: 100, height: 128)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.primary.opacity(selected ? 0.18 : (hovering ? 0.1 : 0.06))))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button { withAnimation(.snappy) { shelf.remove([item.id]) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Remove from shelf")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { shelf.toggleSelection(item) } }
        .onDrag {
            NSItemProvider(contentsOf: shelf.url(for: item)) ?? NSItemProvider()
        }
        .help("\(item.name) — drag out to use, double-click to open")
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DropHint: View {
    let targeted: Bool
    let large: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: large ? 26 : 20, weight: .semibold))
                .symbolEffect(.bounce, value: targeted)
            Text(large ? "Drop files, images, links or text to keep them here" : "Drop here")
                .font(.system(size: large ? 12.5 : 11, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .frame(maxWidth: large ? .infinity : 100, maxHeight: large ? .infinity : 128)
        .frame(width: large ? nil : 100, height: large ? nil : 128)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(targeted ? 0.15 : 0)))
        .padding(.horizontal, large ? 16 : 0)
    }
}
