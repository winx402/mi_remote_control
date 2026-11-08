import AppKit
import SwiftUI

/// Indices are shared with the remote: favorite apps first, followed by the catalog.
/// Layout: up to six apps in one row, three system columns, three confirmation actions.
@MainActor
struct SystemMenuDashboardView: View {
    let apps: [DockApplications.Entry]
    let selected: Int
    let confirming: Bool
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("系统功能")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
            }
            .frame(height: 28)

            if !apps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("常用 App")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(Array(apps.prefix(6).enumerated()), id: \.element.id) { index, app in
                            appButton(app, index: index)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("系统操作")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(SystemMenuCatalog.items.enumerated()).filter { !$0.element.dangerous }, id: \.offset) { index, item in
                        systemButton(item, index: apps.count + index)
                    }
                }
            }

            VStack(spacing: 12) {
                Divider().opacity(0.7)
                HStack(spacing: 8) {
                    ForEach(Array(SystemMenuCatalog.items.enumerated()).filter { $0.element.dangerous }, id: \.offset) { index, item in
                        SystemMenuConfirmationButton(
                            item: item,
                            isSelected: selected == apps.count + index,
                            confirming: confirming && selected == apps.count + index,
                            onSelect: { onSelect(apps.count + index) },
                            onActivate: { onActivate(apps.count + index) }
                        )
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 700)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: 17, alignment: .leading)
    }

    private func appButton(_ app: DockApplications.Entry, index: Int) -> some View {
        Button {
            onSelect(index)
            onActivate(index)
        } label: {
            VStack(spacing: 5) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                Text(app.name)
                    .font(.system(size: 13, weight: selected == index ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .modifier(SystemMenuSelection(isSelected: selected == index, cornerRadius: 12, restingFill: false))
        }
        .buttonStyle(.plain)
        .help("打开 \(app.name)")
        .accessibilityLabel(app.name)
        .accessibilityHint("打开应用")
        .accessibilityAddTraits(selected == index ? .isSelected : [])
    }

    private func systemButton(_ item: SystemMenuItem, index: Int) -> some View {
        Button {
            onSelect(index)
            onActivate(index)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected == index ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                Text(item.title)
                    .font(.system(size: 16, weight: selected == index ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .modifier(SystemMenuSelection(isSelected: selected == index, cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == index ? .isSelected : [])
    }
}

private struct SystemMenuSelection: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    var restingFill = true

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(restingFill ? 0.035 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(restingFill ? 0.055 : 0),
                                  lineWidth: isSelected ? 2.5 : 1)
            }
    }
}

/// A regular click only selects. Execution is exclusively the completed hold gesture.
private struct SystemMenuConfirmationButton: View {
    let item: SystemMenuItem
    let isSelected: Bool
    let confirming: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void

    @State private var pointerHolding = false
    @State private var pointerHoldCancelled = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Text("按住确认")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ZStack {
                    if isSelected && (confirming || pointerHolding) {
                        SystemMenuHoldProgress(duration: SystemMenuCatalog.confirmHoldSeconds)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .modifier(SystemMenuSelection(isSelected: isSelected, cornerRadius: 10, restingFill: false))
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: SystemMenuCatalog.confirmHoldSeconds, maximumDistance: 12) {
            // Moving the remote selection away also disarms a pointer hold.
            guard isSelected, !pointerHoldCancelled else { return }
            onActivate()
        } onPressingChanged: { pressing in
            pointerHolding = pressing
            if pressing {
                pointerHoldCancelled = false
                onSelect()
            }
        }
        .onChange(of: isSelected) { _, selected in
            if !selected {
                pointerHolding = false
                pointerHoldCancelled = true
            }
        }
        .help("按住 \(SystemMenuCatalog.confirmHoldSeconds.formatted()) 秒以\(item.title)")
        .accessibilityLabel(item.title)
        .accessibilityHint("按住以确认；单击只选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SystemMenuHoldProgress: View {
    let duration: TimeInterval
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: duration)) { progress = 1 }
        }
        .accessibilityHidden(true)
    }
}
