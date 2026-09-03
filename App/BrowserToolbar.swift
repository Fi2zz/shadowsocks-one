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
    /// 动画由根视图 toolbarCollapsed 的 spring 驱动。
    /// 静止态一律不带 scaleEffect：变换常驻会把玻璃压平成过渡渲染、丢掉 tint
    var body: some View {
        ZStack(alignment: .bottom) {
            scaledExpandedBar
            scaledCollapsedPill
        }
        // 按钮单色（对齐 Safari）：黑白随深浅色自适应；
        // 状态点（statusColor）与进度线（accentColor）不受 tint 影响
        .tint(.primary)
        .animation(.easeInOut(duration: 0.2), value: addressFocused)
        .onChange(of: addressFocused) { focused in
            handleFocusChange(focused)
        }
    }

    @ViewBuilder
    private var scaledExpandedBar: some View {
        if browser.toolbarCollapsed {
            expandedBar(glassy: false)
                .opacity(0)
                .scaleEffect(BrowserChromeMetrics.toolbarCollapseScale, anchor: .bottom)
                .allowsHitTesting(false)
        } else {
            expandedBar(glassy: true)
        }
    }

    @ViewBuilder
    private var scaledCollapsedPill: some View {
        if browser.toolbarCollapsed {
            collapsedPill(glassy: true)
        } else {
            collapsedPill(glassy: false)
                .opacity(0)
                .scaleEffect(BrowserChromeMetrics.toolbarCollapseScale, anchor: .bottom)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 展开态整条工具栏

    private func expandedBar(glassy: Bool) -> some View {
        HStack(spacing: 12) {
            if !addressFocused {
                navigationButtons(glassy: glassy).transition(.opacity)
            }
            addressFieldCapsule(glassy: glassy)
            trailingButton(glassy: glassy)
        }
        .padding(.horizontal, 12)
        .padding(.top, BrowserChromeMetrics.barVerticalPadding)
        .padding(.bottom, BrowserChromeMetrics.barBottomPadding)
    }

    @ViewBuilder
    private func trailingButton(glassy: Bool) -> some View {
        if addressFocused {
            iconButton(systemImage: "xmark", glassy: glassy) { addressFocused = false }
        } else {
            iconButton(systemImage: "ellipsis", glassy: glassy, action: showMore)
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

    /// REASON: SwiftUI TextField 无公开的全选 API，只能借 responder 链向
    /// 第一响应者发 selectAll:，且要等焦点真正落位后一拍再发；等系统提供
    /// 公开能力后清理。
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
    private func navigationButtons(glassy: Bool) -> some View {
        if browser.canGoForward {
            HStack(spacing: 22) {
                navButton("chevron.left", action: browser.goBack)
                    .disabled(!browser.canGoBack)
                navButton("chevron.right", action: browser.goForward)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, BrowserChromeMetrics.capsuleVerticalPadding)
            .liquidGlassCapsule(enabled: glassy)
        } else {
            navButton("chevron.left", action: browser.goBack)
                .disabled(!browser.canGoBack)
                .padding(BrowserChromeMetrics.capsuleVerticalPadding)
                .liquidGlassCapsule(enabled: glassy)
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

    private func addressFieldCapsule(glassy: Bool) -> some View {
        fieldCluster
            .frame(height: BrowserChromeMetrics.fieldContentHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, BrowserChromeMetrics.capsuleVerticalPadding)
            .liquidGlassCapsule(enabled: glassy)
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

    private func iconButton(systemImage: String, glassy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
        }
        .padding(BrowserChromeMetrics.capsuleVerticalPadding)
        .liquidGlassCapsule(enabled: glassy)
    }

    // MARK: - 收缩态迷你胶囊

    /// 对齐 Safari 迷你条：host 单行 plain 深色，点击展开工具栏
    private func collapsedPill(glassy: Bool) -> some View {
        Text(browser.activePageURL?.host ?? "")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(minWidth: BrowserChromeMetrics.collapsedPillMinWidth)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .liquidGlassCapsule(enabled: glassy)
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
