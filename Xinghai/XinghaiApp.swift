import SwiftUI

@main
struct XinghaiApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            /* 回到前台：网络环境可能已经变了（比如从 5G 换到 Wi-Fi），
               把「还没补写上的那台」再试一次，静默进行，不打扰用户。
               这里故意不重新续登录态 —— refresh_token 是一次性轮换的，
               频繁续期反而会互相踩（后一次拿到 invalid_grant 会把登录态清掉）。 */
            if phase == .active { AppState.shared.flushPending() }
        }
    }
}
