import SwiftUI

/// 与安卓 NX 版一致的暖纸配色。
/// 安卓侧的对应值：paper #F7F4EC、ink #14161A、ink2 #5C6270、mut #666D78、
/// faint #8A8F98、accent #1E4F76、输入框 8% 墨、发丝线 10% 墨。
enum Theme {
    static let paper  = Color(red: 0.969, green: 0.957, blue: 0.925)   // #F7F4EC
    static let paper2 = Color(red: 0.949, green: 0.933, blue: 0.894)   // #F2EEE4
    static let paper3 = Color(red: 0.925, green: 0.906, blue: 0.859)   // #ECE7DB

    static let ink    = Color(red: 0.078, green: 0.086, blue: 0.102)   // #14161A
    static let ink2   = Color(red: 0.361, green: 0.384, blue: 0.439)   // #5C6270
    static let mut    = Color(red: 0.400, green: 0.427, blue: 0.471)   // #666D78
    static let faint  = Color(red: 0.541, green: 0.561, blue: 0.596)   // #8A8F98

    static let accent = Color(red: 0.118, green: 0.310, blue: 0.463)   // #1E4F76
    static let danger = Color(red: 0.639, green: 0.227, blue: 0.188)   // #A33A30

    /// 输入框 / 分段凹槽：8% 淡墨（与安卓 SEG_TRACK 一致，不再是暖黄色块）
    static let field  = Color.black.opacity(0.08)
    /// 发丝线
    static let hair   = Color.black.opacity(0.10)

    /// 全 App 的字号梯度（苹方由系统中文默认字体提供，这里只统一字号）
    enum F {
        static let hero   = Font.system(size: 34, weight: .semibold)
        static let title  = Font.system(size: 20, weight: .semibold)
        static let body   = Font.system(size: 15)
        static let label  = Font.system(size: 12)
        static let tiny   = Font.system(size: 10.5)
    }
}

extension View {
    /// 页面根背景：暖纸色，铺满安全区
    func paperBackground() -> some View {
        self.background(Theme.paper.ignoresSafeArea())
    }

    /// 卡片：暖白半透明 + 发丝线（与安卓弹窗内的次级卡片同款）
    func paperCard(radius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Theme.hair, lineWidth: 0.8)
            )
    }
}
