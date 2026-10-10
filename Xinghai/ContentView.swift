import SwiftUI

struct ContentView: View {
    @ObservedObject private var app = AppState.shared
    @State private var tab = ContentView.launchTab
    @Environment(\.scenePhase) private var scenePhase

    /// 调试用：启动参数 -tab 0/1/2 可直接打开指定页（云端模拟器截图用）
    static var launchTab: Int {
        if let idx = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-tab" }).dropFirst().first {
            return min(max(Int(idx) ?? 0, 0), 2)
        }
        return 0
    }

    var body: some View {
        TabView(selection: $tab) {
            TimetableView()
                .tabItem { Label("课表", systemImage: "tablecells") }
                .tag(0)
            CalendarView()
                .tabItem { Label("台历", systemImage: "calendar") }
                .tag(1)
            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .overlay(alignment: .top) { toastView }
        .animation(.easeInOut(duration: 0.25), value: app.toast)
        .onChange(of: scenePhase) { phase in
            /* 回到前台做两件事：
               ① 把「还没补写上的那台」再试一次（静默）；
               ② 体检登录态 —— 用户反馈过「有时候随机掉其中一个」，掉的那一刻可能
                  就发生在后台期间，只等启动时那一次续期根本兜不住。
                  checkSessions 内部有 60 秒节流 + 互斥，且只有在「成功换到新 token」
                  时才把新 refresh_token 存回，所以不会出现「频繁续期互相踩」。 */
            if phase == .active {
                app.flushPending()
                app.checkSessions()
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = app.toast {
            Text(t)
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .transition(.opacity)
                .zIndex(99)
        }
    }
}

struct BannerView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.85))
    }
}

extension Course {
    /// 课程名散列 → 色板（与安卓版 U 配色思路一致）
    var color: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .pink, .indigo, .mint]
        var h = 5381
        for ch in n.unicodeScalars { h = (h &* 33 &+ Int(ch.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}
