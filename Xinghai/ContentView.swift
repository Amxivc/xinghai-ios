import SwiftUI

struct ContentView: View {
    @ObservedObject private var app = AppState.shared
    @State private var tab = ContentView.launchTab
    @Environment(\.scenePhase) private var scenePhase

    private let TAB = ["课表", "台历", "我的"]

    /// 调试用：启动参数 -tab 0/1/2 可直接打开指定页（云端模拟器截图用）
    static var launchTab: Int {
        if let idx = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-tab" }).dropFirst().first {
            return min(max(Int(idx) ?? 0, 0), 2)
        }
        return 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            /* 不用系统 TabView —— 底部要换成可自定义的液态玻璃胶囊，
               TabView 的 tabItem 无法接管成 glassEffect。 */
            Group {
                switch tab {
                case 1:  CalendarView()
                case 2:  MineView()
                default: TimetableView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /* 给胶囊让出位置，内容滚到底也不会被它压住 */
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 74) }

            dockBar
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
        }
        .background(Theme.paper.ignoresSafeArea())
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

    /// 底部胶囊：iOS 26+ 走系统 Liquid Glass，旧系统降级为 ultraThinMaterial
    private var dockBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { tab = i }
                } label: {
                    Text(TAB[i])
                        .font(.system(size: 13, weight: tab == i ? .semibold : .regular))
                        .foregroundColor(tab == i ? .white : Theme.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if tab == i {
                                Capsule().fill(Theme.ink)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(height: 52)
        .liquidGlassCapsuleTinted(Color.accentColor.opacity(0.10))
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = app.toast {
            Text(t)
                .font(.footnote)
                .foregroundColor(Theme.paper)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.ink.opacity(0.88)))
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
