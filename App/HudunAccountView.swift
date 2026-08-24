import SwiftUI

/// 护盾账号入口页：未登录显示登录表单，已登录显示资料与线路。
struct HudunAccountView: View {
    @ObservedObject var session: HudunSessionViewModel

    var body: some View {
        NavigationStack {
            List {
                switch session.authState {
                case .loggedOut:
                    HudunLoginSection(session: session)
                case .loggedIn:
                    HudunProfileSection(session: session)
                }
            }
            .navigationTitle("护盾账号")
            .navigationBarTitleDisplayMode(.inline)
            .task { await session.restoreSessionIfNeeded() }
        }
        .presentationDetents([.medium, .large])
    }
}
