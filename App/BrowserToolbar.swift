import SwiftUI
import SharedCore

struct BrowserToolbar: View {
    @ObservedObject var tabManager: BrowserTabManager
    @ObservedObject var browser: BrowserViewModel
    let connectionState: ConnectionState
    @FocusState.Binding var addressFocused: Bool
    let showMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if expandedLayout {
                navigationButtons.transition(.opacity)
            }
            addressCapsule
            if !browser.toolbarCollapsed {
                trailingButton.transition(.opacity)
            }
        }
        .padding(.horizontal, browser.toolbarCollapsed ? 0 : 12)
        .padding(.top, browser.toolbarCollapsed ? 0 : BrowserChromeMetrics.barVerticalPadding)
        .padding(.bottom, browser.toolbarCollapsed ? 0 : BrowserChromeMetrics.barBottomPadding)
        .animation(.easeInOut(duration: 0.2), value: addressFocused)
        .onChange(of: addressFocused) { focused in
            handleFocusChange(focused)
        }
    }

    /// 展开布局 = 工具栏未折叠且地址栏未聚焦（聚焦时隐藏导航按钮放大地址胶囊）
    private var expandedLayout: Bool {
        !browser.toolbarCollapsed && !addressFocused
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
            HStack(spacing: 28) {
                navButton("chevron.left", action: browser.goBack)
                    .disabled(!browser.canGoBack)
                navButton("chevron.right", action: browser.goForward)
            }
            .padding(.horizontal, 24)
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

    // MARK: - 地址栏

    private var pageLoaded: Bool {
        tabManager.selectedTab?.url != nil
    }

    /// 地址胶囊：展开/收缩共享同一视图身份，内边距与内容切换随折叠动画插值，
    /// 收缩态点击展开工具栏（TapGesture 只在折叠时响应，展开态交给 TextField）
    private var addressCapsule: some View {
        HStack(spacing: 8) {
            if browser.toolbarCollapsed {
                pillLabel.transition(.opacity)
            } else {
                fieldCluster.transition(.opacity)
            }
        }
        .frame(height: browser.toolbarCollapsed ? nil : BrowserChromeMetrics.fieldContentHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, verticalCapsulePadding)
        .liquidGlassCapsule()
        .overlay(alignment: .bottom) { loadingProgressLine }
        .onTapGesture {
            if browser.toolbarCollapsed {
                browser.expandToolbar()
            }
        }
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

    private var verticalCapsulePadding: CGFloat {
        browser.toolbarCollapsed ? 7 : BrowserChromeMetrics.capsuleVerticalPadding
    }

    /// 收缩态胶囊文字：host 单行，plain 深色（对齐 Safari 迷你条）
    private var pillLabel: some View {
        Text(browser.activePageURL?.host ?? "")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
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

    private func showFullAddress() {
        guard let fullAddress = browser.activePageURL?.absoluteString else {
            return
        }
        browser.addressText = fullAddress
    }
}
