import SwiftUI
import SharedCore

struct BrowserToolbar: View {
    @ObservedObject var tabManager: BrowserTabManager
    @ObservedObject var browser: BrowserViewModel
    let connectionState: ConnectionState
    @FocusState.Binding var addressFocused: Bool
    let showMore: () -> Void

    /// 折叠/展开 = 两个完整状态常驻、作为整体 scale + 交叉淡入淡出
    /// （对齐 Safari：整条工具栏缩放进出迷你胶囊，不做按元素形变）；
    /// 动画由根视图 toolbarCollapsed 的 spring 驱动
    var body: some View {
        ZStack(alignment: .bottom) {
            expandedBar
                .opacity(browser.toolbarCollapsed ? 0 : 1)
                .scaleEffect(barScale, anchor: .bottom)
                .allowsHitTesting(!browser.toolbarCollapsed)
            collapsedPill
                .opacity(browser.toolbarCollapsed ? 1 : 0)
                .scaleEffect(pillScale, anchor: .bottom)
                .allowsHitTesting(browser.toolbarCollapsed)
        }
        .animation(.easeInOut(duration: 0.2), value: addressFocused)
        .onChange(of: addressFocused) { focused in
            handleFocusChange(focused)
        }
    }

    private var barScale: CGFloat {
        browser.toolbarCollapsed ? BrowserChromeMetrics.toolbarCollapseScale : 1
    }

    private var pillScale: CGFloat {
        browser.toolbarCollapsed ? 1 : BrowserChromeMetrics.toolbarCollapseScale
    }

    // MARK: - 展开态整条工具栏

    private var expandedBar: some View {
        HStack(spacing: 12) {
            if !addressFocused {
                navigationButtons.transition(.opacity)
            }
            addressFieldCapsule
            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.top, BrowserChromeMetrics.barVerticalPadding)
        .padding(.bottom, BrowserChromeMetrics.barBottomPadding)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if addressFocused {
            iconButton(systemImage: "xmark") { addressFocused = false }
        } else {
            iconButton(systemImage: "ellipsis", action: showMore)
        }
    }

    private func handleFocusChange(_ focused: Bool) {
        if focused {
            showFullAddress()
            selectAllText()
            return
        }
        browser.addressText = browser.activePageURL?.host ?? ""
    }

    private func selectAllText() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UIApplication.shared.sendAction(
                #selector(UIResponder.selectAll(_:)),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    // MARK: - 前进 / 后退

    @ViewBuilder
    private var navigationButtons: some View {
        if browser.canGoForward {
            HStack(spacing: 22) {
                navButton("chevron.left", action: browser.goBack)
                    .disabled(!browser.canGoBack)
                navButton("chevron.right", action: browser.goForward)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, BrowserChromeMetrics.capsuleVerticalPadding)
            .liquidGlassCapsule()
        } else {
            navButton("chevron.left", action: browser.goBack)
                .disabled(!browser.canGoBack)
                .padding(BrowserChromeMetrics.capsuleVerticalPadding)
                .liquidGlassCapsule()
        }
    }

    private func navButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - 地址栏（展开态）

    private var pageLoaded: Bool {
        tabManager.selectedTab?.url != nil
    }

    private var addressFieldCapsule: some View {
        fieldCluster
            .frame(height: BrowserChromeMetrics.fieldContentHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, BrowserChromeMetrics.capsuleVerticalPadding)
            .liquidGlassCapsule()
            .overlay(alignment: .bottom) { loadingProgressLine }
    }

    /// 加载进度线：贴在地址胶囊内底边（对齐 Safari），无轨道、只画填充段，
    /// 宽度随 progress 插值（根视图已对 progress 挂 easeOut 动画）
    @ViewBuilder
    private var loadingProgressLine: some View {
        if browser.progress > 0, browser.progress < 1 {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * browser.progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            .transition(.opacity)
        }
    }

    private var fieldCluster: some View {
        HStack(spacing: 8) {
            leadingIcon
            TextField("搜索或输入网站", text: $browser.addressText)
                .font(.body)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(browser.loadAddress)
            if addressFocused, !browser.addressText.isEmpty {
                clearButton
            }
            if pageLoaded {
                reloadButton
            }
        }
    }

    private var leadingIcon: some View {
        Group {
            if pageLoaded {
                statusDot
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(connectionState.statusColor)
            .frame(width: 8, height: 8)
    }

    private var clearButton: some View {
        Button {
            browser.addressText = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var reloadButton: some View {
        Button(action: browser.reload) {
            Image(systemName: "arrow.clockwise")
                .font(.body)
                .frame(width: 24, height: 24)
        }
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
        }
        .padding(BrowserChromeMetrics.capsuleVerticalPadding)
        .liquidGlassCapsule()
    }

    // MARK: - 收缩态迷你胶囊

    /// 对齐 Safari 迷你条：host 单行 plain 深色，点击展开工具栏
    private var collapsedPill: some View {
        Text(browser.activePageURL?.host ?? "")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .liquidGlassCapsule()
            .overlay(alignment: .bottom) { loadingProgressLine }
            .onTapGesture(perform: browser.expandToolbar)
    }

    private func showFullAddress() {
        guard let fullAddress = browser.activePageURL?.absoluteString else {
            return
        }
        browser.addressText = fullAddress
    }
}
