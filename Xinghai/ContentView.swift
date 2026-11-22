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
            /* 只留 24pt 余量：内容能滚到胶囊**下面**，玻璃才有东西可透、才看得出液态玻璃；
               留 74pt 会把内容全推上去，胶囊背后永远是纯色，玻璃看起来就像死灰块。 */
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 22) }

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

    /// 底部胶囊：观感对齐台历那排「全部/已完成/未完成」的原生分段控件 ——
    /// 浅灰底 + **白色滑块** + 细阴影，选中项黑字、未选中灰字。
    private var dockBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.88)) { tab = i }
                } label: {
                    Text(TAB[i])
                        .font(.system(size: 13, weight: tab == i ? .semibold : .regular))
                        .foregroundColor(tab == i ? Theme.ink : Theme.mut)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if tab == i {
                                /* 滑块用半透明白：在玻璃底上能透出一点后面的颜色，才像同一块材质 */
                                Capsule().fill(Color.white.opacity(0.82))
                                    .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 40)
        /* 液态玻璃底：iOS 26 走系统 glassEffect（真玻璃，会折射背后内容），
           旧系统降级 ultraThinMaterial（磨砂）。绝不能再铺不透明灰 —— 那样就没有玻璃感。 */
        .liquidGlassCapsule()
        /* 液态玻璃的灵魂是「边缘高光」：上沿一道亮白、下沿转暗。
           只靠 glassEffect/ultraThinMaterial 在纯色背景上几乎看不出玻璃感，
           补这圈描边后无论在模拟器还是真机都像一块玻璃。 */
        .overlay(
            Capsule().stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.75), Color.white.opacity(0.10),
                             Color.black.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 5)
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
