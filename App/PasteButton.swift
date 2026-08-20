import SwiftUI
import UIKit

/// 系统粘贴按钮（UIPasteControl）：用户点击触发的粘贴不弹隐私授权框，
/// 替代程序化读取 UIPasteboard（每次渲染都会触发授权弹窗）。
struct PasteButton: UIViewRepresentable {
    let onPaste: (String) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.cornerStyle = .capsule
        configuration.displayMode = .iconAndLabel

        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ uiView: UIPasteControl, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    final class Coordinator: UIResponder {
        private let acceptedConfiguration = UIPasteConfiguration(forAccepting: String.self)
        private let onPaste: (String) -> Void

        override var pasteConfiguration: UIPasteConfiguration? {
            get { acceptedConfiguration }
            set {}
        }

        init(onPaste: @escaping (String) -> Void) {
            self.onPaste = onPaste
            super.init()
        }

        override func paste(itemProviders: [NSItemProvider]) {
            for provider in itemProviders {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string else {
                        return
                    }
                    Task { @MainActor in
                        self.onPaste(string)
                    }
                }
            }
        }

        override func paste(_ sender: Any?) {
            guard let string = UIPasteboard.general.string else {
                return
            }
            onPaste(string)
        }
    }
}
