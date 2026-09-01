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
            if !addressFocused {
                navigationButtons
            }
            addressField
            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.top, BrowserChromeMetrics.barVerticalPadding)
        .padding(.bottom, BrowserChromeMetrics.barBottomPadding)
        .animation(.easeInOut(duration: 0.2), value: addressFocused)
        .onChange(of: addressFocused) { focused in
            handleFocusChange(focused)
        }
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
                .font(.title2)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - 地址栏

    private var pageLoaded: Bool {
        tabManager.selectedTab?.url != nil
    }

    private var addressField: some View {
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
            if !browser.addressText.isEmpty {
                clearButton
            }
            if pageLoaded {
                reloadButton
            }
        }
        .frame(height: BrowserChromeMetrics.fieldContentHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, BrowserChromeMetrics.capsuleVerticalPadding)
        .liquidGlassCapsule()
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
                .font(.title3)
                .frame(width: 24, height: 24)
        }
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
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
