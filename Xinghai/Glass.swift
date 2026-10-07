import SwiftUI

extension View {
    /// 液态玻璃容器：iOS 26+ 用系统 Liquid Glass；旧系统降级为普通毛玻璃材质
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(),
                             in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    /// 胶囊形液态玻璃（用于小按钮 / 标签）
    @ViewBuilder
    func liquidGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}
