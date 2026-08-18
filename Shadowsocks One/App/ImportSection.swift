import SwiftUI
import UIKit

struct ImportSection: View {
    @Binding var rawURL: String
    let importAction: () -> Void
    @FocusState private var editorFocused: Bool

    private var hasInput: Bool {
        !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var clipboardText: String {
        UIPasteboard.general.string ?? ""
    }

    private func triggerImport() {
        editorFocused = false
        DispatchQueue.main.async {
            importAction()
        }
    }

    var body: some View {
        Section("导入节点") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $rawURL)
                    .focused($editorFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 160)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .contextMenu {
                        Button("粘贴") {
                            rawURL = clipboardText
                            editorFocused = true
                        }
                        .disabled(clipboardText.isEmpty)

                        Button("清空", role: .destructive) {
                            rawURL = ""
                            editorFocused = true
                        }
                        .disabled(!hasInput)
                    }

                if rawURL.isEmpty {
                    Text("粘贴 `ss://` 节点到这里")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Button("粘贴") {
                    rawURL = clipboardText
                    editorFocused = true
                }
                .disabled(clipboardText.isEmpty)

                Button("清空") {
                    rawURL = ""
                    editorFocused = true
                }
                .disabled(!hasInput)

                Spacer()

                Button("导入并保存", action: triggerImport)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasInput)
            }
        }
    }
}
