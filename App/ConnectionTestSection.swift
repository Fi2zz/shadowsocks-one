import SwiftUI

/// 连通性测试入口：连接节点后输入 URL 发一次真实请求，验证流量是否走通。
struct ConnectionTestSection: View {
    @State private var urlText = "https://www.google.com/generate_204"
    @State private var testing = false
    @State private var result: ConnectionTestResult?
    private let tester = ConnectionTester()

    var body: some View {
        Section {
            TextField("https://www.google.com/generate_204", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Button("测试连接", action: runTest)
                    .disabled(testing || ConnectionTester.normalizeURL(from: urlText) == nil)
                Spacer()
                statusLabel
            }
        } header: {
            Text("连接测试")
        } footer: {
            Text("先连接节点再测试；请求走系统 VPN 通道。默认地址通则表示代理链路可用，也可填国内地址验证直连。")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if testing {
            ProgressView()
                .controlSize(.small)
        } else if let result {
            Text(result.summaryText)
                .font(.footnote)
                .foregroundStyle(result.succeeded ? Color.green : Color.red)
        }
    }

    private func runTest() {
        testing = true
        result = nil
        Task {
            let outcome = await tester.test(urlString: urlText)
            result = outcome
            testing = false
        }
    }
}
