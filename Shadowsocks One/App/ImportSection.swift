import SwiftUI

struct ImportSection: View {
    @Binding var rawURL: String
    let importAction: () -> Void

    var body: some View {
        Section("导入节点") {
            TextField("ss://", text: $rawURL, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)

            Button("导入并保存", action: importAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
