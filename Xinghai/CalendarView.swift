import SwiftUI

struct CalendarView: View {
    @ObservedObject private var app = AppState.shared
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var selDay = M.todayIso()

    var body: some View {
        VStack(spacing: 0) {
            if let b = app.banner {
                BannerView(text: b)
            }
            navBar
            Divider()
            ScrollView {
                monthGrid
                statsLine
                Divider().padding(.vertical, 6)
                dayList
            }
        }
        .task { if app.persons.isEmpty { app.load() } }
    }

    /* ================= 月份导航 ================= */

    private var navBar: some View {
        HStack(spacing: 12) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text("\(String(year)) 年 \(month) 月").font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Divider().frame(height: 18)
            Button("今天") {
                let c = Calendar.current.dateComponents([.year, .month], from: Date())
                year = c.year ?? year
                month = c.month ?? month
                selDay = M.todayIso()
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func shiftMonth(_ delta: Int) {
        var c = DateComponents(year: year, month: month)
        c.month = (c.month ?? 1) + delta
        if let d = Calendar.current.date(from: c) {
            let comp = Calendar.current.dateComponents([.year, .month], from: d)
            year = comp.year ?? year
            month = comp.month ?? month
        }
    }

    /* ================= 月历网格 ================= */

    private var monthGrid: some View {
        let daysInMonth = Calendar.current.range(of: .day, in: .month,
                                                 for: Calendar.current.date(from: DateComponents(year: year, month: month)))?.count ?? 30
        let firstWeekday = { () -> Int in
            guard let first = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) else { return 0 }
            let wd = Calendar.current.component(.weekday, from: first)   // 1=周日
            return (wd + 5) % 7   // 0=周一
        }()
        let cells: [Int] = Array(repeating: 0, count: firstWeekday) + Array(1...daysInMonth)
        return VStack(spacing: 6) {
            HStack {
                ForEach(M.days, id: \.self) {
                    Text($0).font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                      spacing: 6) {
                ForEach(cells.indices, id: \.self) { i in
                    let day = cells[i]
                    if day == 0 {
                        Color.clear.frame(height: 44)
                    } else {
                        dayCell(day)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func dayCell(_ day: Int) -> some View {
        let iso = String(format: "%04d-%02d-%02d", year, month, day)
        let dayWorks = app.works.filter { M.workDate($0) == iso && $0.hasContent }
        let isSel = selDay == iso
        let isToday = iso == M.todayIso()
        return Button {
            selDay = iso
        } label: {
            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.system(size: 14, weight: isToday ? .bold : .regular))
                    .foregroundColor(isSel ? .white : (isToday ? .blue : .primary))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(isSel ? Color.blue : Color.clear))
                    .overlay(Circle().stroke(isToday && !isSel ? Color.blue : Color.clear,
                                             lineWidth: 1))
                Circle()
                    .fill(dotColor(dayWorks))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ list: [WorkRow]) -> Color {
        guard !list.isEmpty else { return .clear }
        return list.allSatisfy { $0.done } ? .green : .orange
    }

    private var statsLine: some View {
        let (total, done, pending) = M.workStats(year, month, works: app.works)
        return Text("\(month) 月共 \(total) 条记录 · 已完成 \(done) · 未完成 \(pending)")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    /* ================= 选中日列表 ================= */

    private var dayList: some View {
        let list = app.works.filter { M.workDate($0) == selDay && $0.hasContent }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(M.formatCn(selDay)).font(.subheadline.weight(.medium))
                Spacer()
                Text("共 \(list.count) 项")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            if list.isEmpty {
                Text("当天暂无工作安排")
                    .font(.footnote).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(list.indices, id: \.self) { i in
                    workCard(list[i])
                }
            }
        }
        .padding(.bottom, 20)
    }

    private func workCard(_ r: WorkRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(r.activity.isEmpty ? "（未填写活动）" : r.activity)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(r.statusText)
                    .font(.caption2)
                    .foregroundColor(r.done ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(r.done ? Color.green.opacity(0.12)
                                                      : Color.orange.opacity(0.12)))
            }
            if !r.name.isEmpty {
                Text("负责人：" + r.name).font(.caption).foregroundColor(.secondary)
            }
            if !r.setupTime.isEmpty {
                Text("布置：" + r.setupTime).font(.caption).foregroundColor(.secondary)
            }
            if !r.content.isEmpty {
                Text(r.content).font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(UIColor.secondarySystemGroupedBackground)))
        .padding(.horizontal, 16)
    }
}
