import SwiftUI
import SharedCore

struct BrowserToolbar: View {
    @ObservedObject var tabManager: BrowserTabManager
    let connectionState: ConnectionState
    let showMore: () -> Void

    @State private var addressInput = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            if !addressFocused {
                navigationButtons
            }
            addressField
            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: addressFocused)
        .onChange(of: addressFocused) { focused in
            handleFocusChange(focused)
        }
        .onChange(of: tabManager.selectedTabID) { _ in syncAddressInput() }
        .onChange(of: tabManager.selectedTab?.currentURL) { _ in syncAddressInput() }
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
            selectAllText()
            return
        }
        syncAddressInput()
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

    @ViewBuilder
    private var navigationButtons: some View {
        if canGoForward {
            HStack(spacing: 28) {
                backButton
                forwardButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .liquidGlassCapsule()
        } else {
            backButton
                .padding(14)
                .liquidGlassCapsule()
        }
    }

    private var backButton: some View {
        Button {
            tabManager.selectedTab?.goBack()
        } label: {
            Image(systemName: "chevron.left")
                .font(.title2)
                .frame(width: 24, height: 24)
        }
        .disabled(!canGoBack)
    }

    private var forwardButton: some View {
        Button {
            tabManager.selectedTab?.goForward()
        } label: {
            Image(systemName: "chevron.right")
                .font(.title2)
                .frame(width: 24, height: 24)
        }
    }

    private var canGoBack: Bool {
        tabManager.selectedTab?.canGoBack == true
    }

    private var canGoForward: Bool {
        tabManager.selectedTab?.canGoForward == true
    }

    private var pageLoaded: Bool {
        tabManager.selectedTab?.currentURL != nil
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            leadingIcon
            TextField("搜索或输入网站", text: $addressInput)
                .font(.body)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(submitAddress)
            if !addressInput.isEmpty {
                clearButton
            }
            if pageLoaded {
                reloadButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
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
            addressInput = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var reloadButton: some View {
        Button {
            tabManager.selectedTab?.reload()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.title3)
        }
        .padding(4)
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 24, height: 24)
        }
        .padding(14)
        .liquidGlassCapsule()
    }

    private func submitAddress() {
        guard let url = BrowserURLBuilder.makeURL(from: addressInput) else {
            return
        }
        tabManager.open(url)
    }

    private func syncAddressInput() {
        addressInput = tabManager.selectedTab?.currentURL?.absoluteString ?? ""
    }
}
