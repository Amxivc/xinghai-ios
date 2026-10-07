import SwiftUI

struct ContentView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        TabView {
            TimetableView()
                .tabItem { Label("课表", systemImage: "tablecells") }
            CalendarView()
                .tabItem { Label("台历", systemImage: "calendar") }
            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
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
