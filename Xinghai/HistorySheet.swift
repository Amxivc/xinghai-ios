import SwiftUI

/// 历史版本：每次保存都留过一版，误删 / 被覆盖时能退回去（v0.5.6 起）。
///
/// 数据来源两处，合并展示：
///   ① 本机快照（AppState.localHistoryItems）—— 最快，离线也能用，保留最近 10 版
///   ② 腾讯云历史（Cloud.cbReadHistory）—— 跨设备，保留最近 20 版
/// 同一份改动两边都会留，按「时间 + 规模」去重后按时间倒序。
///
/// ⚠ 部署目标 iOS 15：只用 iOS 15 就有的 API。`.presentationDetents`（16+）、
///   `ShareLink`（16+）、Button 上的 `.fontWeight`（16+）都不能用。
struct HistorySheet: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss

    /// 合并后的一条候选版本
    private struct Item: Identifiable {
        let id = UUID()
        var at: Date?
        var label = ""
        var members = 0, courses = 0, works = 0
        var ver = 0
        var data: [String: Any]?
        var origin = ""          // "本机" / "云端"
    }

    @State private var items: [Item] = []
    @State private var loading = true
    @State private var pending: Item? = nil
    @State private var confirmRestore = false
    @State private var busy = false

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取…").font(.subheadline).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle).foregroundColor(.secondary)
                        Text("还没有历史版本")
                            .font(.headline)
                        Text("升级到本版后，之后每次保存都会自动留一版。")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, it in
                                row(it, isCur: idx == curIdx)
                            }
                        } header: {
                            Text("共 \(items.count) 版，点任意一版可回滚　·　当前 v\(app.curVer)")
                        }
                    }
                }
            }
            .navigationTitle("历史版本")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { reload() }
        .alert("回滚到这一版？", isPresented: $confirmRestore) {
            Button("取消", role: .cancel) { pending = nil }
            Button("回滚到这一版", role: .destructive) { doRestore() }
        } message: {
            if let p = pending {
                Text((p.ver > 0 ? "v\(p.ver)　" : "") + timeText(p.at) + "　" + p.label + "\n"
                     + "\(p.members) 位成员 · \(p.courses) 门课程 · \(p.works) 条记录\n"
                     + "当前数据（v\(app.curVer)）会被这一版替换。")
            }
        }
    }

    private func row(_ it: Item, isCur: Bool) -> some View {
        Button {
            if isCur {
                app.showToast("这一版就是当前数据" + (it.ver > 0 ? "（v\(it.ver)）" : ""))
                return
            }
            pending = it
            confirmRestore = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if it.ver > 0 {
                        Text("v\(it.ver)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(6)
                    }
                    Text(timeText(it.at))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(isCur ? "当前" : it.label)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(6)
                }
                Text("\(it.members) 位成员 · \(it.courses) 门课程 · \(it.works) 条记录　·　\(it.origin)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCur ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    /// 哪一条才是「当前这份数据」？按时间戳最接近 app.cbAt 的那条（1.5s 容差）。
    /// ⚠ 不能按版本号判 —— 好几版可能带同一个号（本机 + 云端各一条）。
    private var curIdx: Int {
        guard let target = app.cbAt else { return -1 }
        var best = -1
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for (i, it) in items.enumerated() {
            guard let d = it.at else { continue }
            let gap = abs(d.timeIntervalSince(target))
            if gap <= 1.5 && gap < bestGap { bestGap = gap; best = i }
        }
        return best
    }

    private func doRestore() {
        guard let p = pending, let data = p.data else { pending = nil; return }
        busy = true
        app.restore(to: data) { _, msg in
            busy = false
            pending = nil
            app.showToast(msg)
            reload()
        }
    }

    private func reload() {
        loading = true
        let localRaw = app.localHistoryItems()
        let token = app.cbToken
        DispatchQueue.global(qos: .userInitiated).async {
            var all: [Item] = []
            /* ① 本机（先入，优先保留 —— 读取最快、离线可用） */
            for o in localRaw {
                guard let data = o["data"] as? [String: Any] else { continue }
                var it = Item()
                it.at = Cloud.parseIso(o["at"] as? String)
                it.label = o["label"] as? String ?? "保存"
                it.members = o["members"] as? Int ?? 0
                it.courses = o["courses"] as? Int ?? 0
                it.works = o["works"] as? Int ?? 0
                it.ver = o["ver"] as? Int ?? 0
                it.data = data
                it.origin = "本机"
                all.append(it)
            }
            /* ② 云端。匿名读会被拒，用登录令牌读（历史都是登录后才有的） */
            if !token.isEmpty {
                if let his = try? Cloud.cbReadHistory(token: token) {
                    for h in his {
                        guard let data = h.data else { continue }
                        var it = Item()
                        it.at = h.at
                        it.label = h.label.isEmpty ? "保存" : h.label
                        it.members = h.members
                        it.courses = h.courses
                        it.works = h.works
                        it.ver = h.ver
                        it.data = data
                        it.origin = "云端"
                        all.append(it)
                    }
                }
            }

            /* 去重：同一次保存会在本机留一份、云端留一份，两边时间戳可能差几毫秒。
               判「同一版」用两条：
                 ① 同一时刻（1.5s 容差）+ 同规模
                 ② 版本号相同 + 同规模 + 时间差在 10 分钟内（换设备补写的场景） */
            var uniq: [Item] = []
            for it in all {
                var dup = false
                for u in uniq {
                    guard u.members == it.members, u.courses == it.courses,
                          u.works == it.works else { continue }
                    let gap = abs((u.at ?? .distantPast).timeIntervalSince(it.at ?? .distantPast))
                    if gap <= 1.5 { dup = true; break }
                    if u.ver > 0 && u.ver == it.ver && gap <= 600 { dup = true; break }
                }
                if !dup { uniq.append(it) }
            }
            /* 同一时刻两条时，谁带版本号就采用谁 —— 老数据没编号，云端那份才有 */
            for i in uniq.indices where uniq[i].ver == 0 {
                for it in all where it.ver > uniq[i].ver {
                    let gap = abs((it.at ?? .distantPast)
                                    .timeIntervalSince(uniq[i].at ?? .distantPast))
                    if gap <= 1.5 { uniq[i].ver = it.ver }
                }
            }
            uniq.sort { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }

            DispatchQueue.main.async {
                self.items = uniq
                self.loading = false
            }
        }
    }

    private func timeText(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}
