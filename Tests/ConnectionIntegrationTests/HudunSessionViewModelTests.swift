import Foundation
import XCTest
@testable import ShadowsocksBrowser

/// 会话层单测：登录/退出/静默恢复/4003 失效（网络层用替身，不触网）。
@MainActor
final class HudunSessionViewModelTests: XCTestCase {

    func testLoginSuccessPersistsCredentialsAndLoadsAccount() async {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        await viewModel.login(account: "13800000000", password: "secret")

        XCTAssertEqual(viewModel.authState, .loggedIn)
        XCTAssertEqual(store.load()?.token, "token-abc")
        XCTAssertEqual(viewModel.account?.phone, "13800000000")
        XCTAssertNil(viewModel.message)
    }

    func testWrongPasswordKeepsLoggedOutAndShowsHint() async {
        let stub = HudunServiceStub()
        stub.loginOutcome = .failure(HudunError.wrongCredentials("bad"))
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        await viewModel.login(account: "13800000000", password: "wrong")

        XCTAssertEqual(viewModel.authState, .loggedOut)
        XCTAssertEqual(viewModel.message, "账号或密码错误")
        XCTAssertNil(store.load())
    }

    func testRestoreWithStoredTokenEntersLoggedInWithoutLoginCall() async {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        try? store.save(HudunCredentials(token: "stored", deviceid: "d", uid: "7"))
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        await viewModel.restoreSessionIfNeeded()

        XCTAssertEqual(viewModel.authState, .loggedIn)
        XCTAssertEqual(stub.loginCalls, 0)
    }

    func testExpiredSessionDuringRestoreClearsStore() async {
        let stub = HudunServiceStub()
        stub.userInfoOutcome = .failure(HudunError.sessionExpired)
        let store = makeTempStore()
        try? store.save(HudunCredentials(token: "stale", deviceid: "d", uid: "7"))
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        await viewModel.restoreSessionIfNeeded()

        XCTAssertEqual(viewModel.authState, .loggedOut)
        XCTAssertNil(store.load())
        XCTAssertTrue(viewModel.message?.contains("登录已失效") == true)
    }

    func testLogoutClearsStoreAndState() async {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        await viewModel.login(account: "u", password: "p")
        viewModel.logout()

        XCTAssertEqual(viewModel.authState, .loggedOut)
        XCTAssertTrue(viewModel.lines.isEmpty)
        XCTAssertNil(viewModel.account)
        XCTAssertNil(store.load())
        XCTAssertEqual(viewModel.message, "已退出登录")
    }

    func testSelectOnlyMarksLineWithoutTouchingNetworkOrHandler() async {
        let stub = HudunServiceStub()
        stub.lines = [makeLine(id: 7)]
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)
        var handlerCalls = 0
        viewModel.connectRequestHandler = { _, _, _ in
            handlerCalls += 1
            return nil
        }

        await viewModel.restoreSessionIfNeeded()
        viewModel.select(stub.lines[0])

        XCTAssertEqual(viewModel.selectedLine?.id, 7)
        XCTAssertEqual(stub.renewCalls, 0)
        XCTAssertEqual(handlerCalls, 0)
    }

    func testBlockedLineCannotBeSelected() {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        viewModel.select(makeLine(id: 8, blocked: true))

        XCTAssertNil(viewModel.selectedLine)
    }

    func testConnectSelectedLineRenewsAndInvokesHandlerWithoutAutoSelect() async {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)
        viewModel.select(makeLine(id: 9))
        var capturedLineID: Int?
        viewModel.connectRequestHandler = { _, lineID, _ in
            capturedLineID = lineID
            return nil
        }

        await viewModel.connectSelectedLine()

        XCTAssertEqual(stub.renewCalls, 1)
        XCTAssertEqual(capturedLineID, 9)
        XCTAssertNil(viewModel.message)
    }

    func testClearSelectedLineForgetsSelectionMemory() {
        let stub = HudunServiceStub()
        let store = makeTempStore()
        let viewModel = HudunSessionViewModel(service: stub, store: store)

        viewModel.select(makeLine(id: 11))
        viewModel.clearSelectedLine()

        XCTAssertNil(viewModel.selectedLine)
        XCTAssertNil(HudunSelectionMemory.savedLineID)
    }

    private func makeLine(id: Int, blocked: Bool = false) -> HudunLine {
        HudunLine(
            id: id,
            name: "线路\(id)",
            typeName: "wg",
            groupName: "默认",
            flagName: "HK",
            ip: "1.2.3.4",
            imageURL: nil,
            vipState: 1,
            isBlocked: blocked,
            tier: "svip")
    }

    private func makeTempStore() -> HudunFileCredentialStore {
        HudunFileCredentialStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("hudun-tests-\(UUID().uuidString)", isDirectory: true))
    }
}

private final class HudunServiceStub: HudunServicing, @unchecked Sendable {
    var loginOutcome = Result<HudunCredentials, Error>.success(
        HudunCredentials(token: "token-abc", deviceid: "device-1", uid: "42"))
    var userInfoOutcome = Result<[String: Any], Error>.success([
        "code": 200,
        "msg": "",
        "data": ["uid": 42, "phone": "13800000000"] as [String: Any],
    ])
    var linesOutcome = Result<[HudunLine], Error>.success([])
    var loginCalls = 0
    var lines: [HudunLine] = []
    var linesOutcomeFails = false
    var renewCalls = 0

    func login(account: String, password: String) async throws -> HudunCredentials {
        loginCalls += 1
        return try loginOutcome.get()
    }

    func postLoginSync() async -> (user: [String: Any]?, checkIn: [String: Any]?, notice: [String: Any]?) {
        (try? userInfoOutcome.get(), nil, nil)
    }

    func userInfo() async throws -> [String: Any] {
        try userInfoOutcome.get()
    }

    func lines() async throws -> [HudunLine] {
        if linesOutcomeFails { throw HudunError.transport("offline") }
        return lines
    }

    func renew(lineId: Int) async throws -> HudunWGConfig {
        renewCalls += 1
        return HudunWGConfig(privateKeyB64: "priv", address: "22.105.98.191",
                             dns: "22.0.0.2", endpoint: "113.45.52.155:19921",
                             peerPublicKey: "peer", mtu: 1300,
                             expiresAt: Date(timeIntervalSinceNow: 3600),
                             confString: "[Interface]")
    }
}
