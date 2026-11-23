import AppKit
import SwiftUI
import WinSwitcherCore

struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

struct SwitcherHUDView: View {
    @ObservedObject var viewModel: SwitcherViewModel
    @ObservedObject var thumbnails: ThumbnailManager
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let onSelectIndex: (Int) -> Void
    let onCloseWindow: (WindowID) -> Void

    var body: some View {
        let metrics = viewModel.gridMetrics
        let columns = Array(
            repeating: GridItem(.fixed(metrics.cardWidth), spacing: metrics.cardSpacing),
            count: max(1, metrics.columns)
        )

        ZStack {
            // Windows 11 Acrylic/Mica translucent shell
            VisualEffectBackdrop(
                material: .hudWindow,
                blendingMode: .behindWindow,
                cornerRadius: 16
            )

            // Subtle surface tint + hairline border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10),
                            lineWidth: 1
                        )
                )

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    Group {
                        if metrics.needsScroll {
                            ScrollView(.vertical, showsIndicators: true) {
                                gridContent(columns: columns, metrics: metrics)
                            }
                        } else {
                            gridContent(columns: columns, metrics: metrics)
                        }
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIdx in
                        if viewModel.windows.indices.contains(newIdx) {
                            withAnimation(.easeOut(duration: 0.08)) {
                                proxy.scrollTo(viewModel.windows[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }

                // Bottom footer bar: full active window title + space/state + compact shortcuts
                footerBar
                    .frame(height: metrics.footerHeight)
            }
        }
        .frame(width: metrics.panelWidth, height: metrics.panelHeight)
    }

    private func gridContent(columns: [GridItem], metrics: SwitcherGridMetrics) -> some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: metrics.cardSpacing) {
            ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, window in
                WindowCardView(
                    window: window,
                    appIcon: WindowTracker.shared.appIcon(for: window.pid),
                    thumbnail: thumbnails.thumbnail(for: window.id),
                    isSelected: index == viewModel.selectedIndex,
                    showSpaceBadge: settings.showSpaceBadge,
                    cardWidth: metrics.cardWidth,
                    cardHeight: metrics.cardHeight,
                    onSelect: { onSelectIndex(index) },
                    onClose: { onCloseWindow(window.id) }
                )
                .id(window.id)
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.verticalPadding)
        .padding(.bottom, 12)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            if let selected = viewModel.selectedWindow {
                if let icon = WindowTracker.shared.appIcon(for: selected.pid) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)
                }

                Text(selected.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if selected.displayTitle != selected.appName {
                    Text("— \(selected.appName)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if selected.isMinimized {
                    footerTag("已最小化")
                } else if selected.isHidden {
                    footerTag("已隐藏")
                }

                if settings.showSpaceBadge, let spaceLabel = selected.spaceKind.descriptiveLabel,
                   selected.spaceKind.isOffCurrentSpace {
                    footerTag(spaceLabel)
                }
            }

            Spacer(minLength: 8)

            Text("Tab 切换 · 方向键 · W 关闭 · Esc 取消")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    private func footerTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
            )
    }
}

private struct WindowCardView: View {
    let window: WindowDescriptor
    let appIcon: NSImage?
    let thumbnail: NSImage?
    let isSelected: Bool
    let showSpaceBadge: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            // Windows 11 card header: app icon + title + space pill + hover close ×
            HStack(spacing: 6) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Text(window.displayTitle)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if showSpaceBadge, let badge = window.spaceKind.shortBadge, !isHovered {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                        )
                }

                if isHovered || isSelected {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isCloseHovered ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isCloseHovered ? Color(red: 0.77, green: 0.17, blue: 0.11) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isCloseHovered = hovering
                    }
                    .help("关闭窗口")
                }
            }
            .frame(height: 18)

            // Thumbnail preview body
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.06))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(window.isMinimizedOrHidden ? 0.62 : 1.0)
                        .padding(2)
                } else if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .opacity(window.isMinimizedOrHidden ? 0.55 : 0.90)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                }

                if window.isMinimizedOrHidden {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label(window.isMinimized ? "最小化" : "隐藏", systemImage: "minus.circle.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule().fill(Color.black.opacity(0.62))
                                )
                                .padding(6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(8)
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: isSelected ? 2.5 : (isHovered ? 1.2 : 0.6))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect()
        }
    }

    private var cardBackgroundColor: Color {
        if isSelected {
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.65)
        }
        if isHovered {
            return colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.42)
        }
        return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.24)
    }

    private var cardBorderColor: Color {
        if isSelected {
            return colorScheme == .dark ? Color.white.opacity(0.92) : Color.accentColor
        }
        if isHovered {
            return colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.20)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}
