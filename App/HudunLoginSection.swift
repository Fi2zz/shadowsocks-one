import SwiftUI

/// 账密登录表单（明文提交由 API 层处理，见文档 §2.1/§3.2）。
struct HudunLoginSection: View {
    @ObservedObject var session: HudunSessionViewModel
    @State private var accountText = ""
    @State private var passwordText = ""

    var body: some View {
        Section("登录") {
            TextField("手机号 / 账号", text: $accountText)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $passwordText)
            loginButton
        }
        MessageSection(message: session.message)
    }

    private var canSubmit: Bool {
        !accountText.trimmingCharacters(in: .whitespaces).isEmpty
            && !passwordText.isEmpty
    }

    private var loginButton: some View {
        Button {
            Task {
                await session.login(
                    account: accountText,
                    password: passwordText)
            }
        } label: {
            HStack {
                Spacer()
                if session.busy {
                    ProgressView()
                } else {
                    Text("登录").bold()
                }
                Spacer()
            }
        }
        .disabled(!canSubmit || session.busy)
    }
}
