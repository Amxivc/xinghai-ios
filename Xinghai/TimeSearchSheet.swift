import SwiftUI

/* =========================================================
   时间查找：选一个日期 + 一段时间，列出所有成员在该时段是否有课、
   以及课程与查询时段的重叠时长（对标安卓 TimeSearchDialog）。
   ========================================================= */

struct TimeSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var app = AppState.shared

    @State private var date = Date()
    @State private var startTime = M.hmToDate("09:00")
    @State private var endTime = M.hmToDate("10:00")
    @State private var hits: [Hit] = []
    @State private var summary = ""
    @State private var hasRun = false

    /// 一位成员在查询时段内的命中情况
    struct Hit: Identifiable {
        let id = UUID()
        let person: Person
        let items: [Item]
    }
    struct Item: Identifiable {
        let id = UUID()
        let course: Course
        let courseStart: Int
        let courseEnd: Int
        let overlapStart: Int
        let overlapEnd: Int
        let overlap: Int
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                conditions
                Divider()
                if hasRun {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(hits) { h in
                                personCard(h)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                } else {
                    Spacer()
                }
            }
            .navigationTitle("时间查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("查询") { run() }
                }
            }
        }
        .onAppear { if !hasRun { run() } }
    }

    /* ================= 查询条件 ================= */

    private var conditions: some View {
        VStack(spacing: 10) {
            HStack {
                Text("日期").font(.subheadline.weight(.semibold))
                Spacer()
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
            }
            HStack {
                Text("开始时间").font(.subheadline.weight(.semibold))
                Spacer()
                DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
            }
            HStack {
                Text("结束时间").font(.subheadline.weight(.semibold))
                Spacer()
                DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
            }
            Text(summary)
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /* ================= 成员卡 ================= */

    private func personCard(_ h: Hit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.person.name).font(.subheadline.weight(.semibold))
                    Text(h.person.cls).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Text(h.items.isEmpty ? "无课" : "有课 · \(h.items.count) 门")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(h.items.isEmpty ? Color(.systemGray6) : Color.blue.opacity(0.12))
                    .foregroundColor(h.items.isEmpty ? .secondary : .blue)
                    .clipShape(Capsule())
            }
            ForEach(h.items) { it in
                Divider().padding(.top, 10)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(M.courseRange(it.course))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.blue)
                        Text("占用 \(M.hhmm(it.overlapStart))—\(M.hhmm(it.overlapEnd))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(width: 86, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.course.n).font(.subheadline.weight(.medium))
                        Text("\(it.course.t.isEmpty ? "教师待定" : it.course.t) · "
                             + "\(it.course.r.isEmpty || it.course.r == "—" ? "教室待定" : it.course.r)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(M.durationText(it.overlap))
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.systemGray6))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                }
                .padding(.top, 10)
            }
        }
        .padding(13)
        .background(h.items.isEmpty ? Color(.systemGray6) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color(.systemGray5), lineWidth: 1))
    }

    /* ================= 计算 ================= */

    private func run() {
        hasRun = true
        var out: [Hit] = []
        let iso = M.dateToIso(date)
        let start = M.clockMinutes(M.hmString(startTime))
        let end = M.clockMinutes(M.hmString(endTime))
        let dateText = M.formatCn(iso)

        guard start >= 0, end > start else {
            summary = "结束时间必须晚于开始时间"
            hits = []
            return
        }
        guard let sd = M.semesterOf(iso) else {
            summary = "\(dateText) · 不在当前学期第 1—\(M.TOTAL_WEEKS) 周范围内"
            for p in app.persons { out.append(Hit(person: p, items: [])) }
            hits = out
            return
        }

        var hasCourse = 0
        var totalOverlap = 0
        for p in app.persons {
            var items: [Item] = []
            for c in p.courses {
                M.normalize(c)
                if c.d != sd.day || !c.inWeek(sd.week) { continue }
                let cm = M.courseMinutes(c)
                let cs = cm.0, ce = cm.1
                if cs < 0 || ce < 0 || ce <= start || cs >= end { continue }
                let os = max(start, cs), oe = min(end, ce)
                let ov = max(0, oe - os)
                if ov <= 0 { continue }
                items.append(Item(course: c, courseStart: cs, courseEnd: ce,
                                  overlapStart: os, overlapEnd: oe, overlap: ov))
            }
            items.sort { $0.courseStart < $1.courseStart }
            if !items.isEmpty { hasCourse += 1 }
            for it in items { totalOverlap += it.overlap }
            out.append(Hit(person: p, items: items))
        }
        hits = out
        if app.persons.isEmpty {
            summary = "还没有成员数据，请先在「我的」里同步。"
            return
        }
        summary = "\(dateText) · 第 \(sd.week) 周 · \(M.days[sd.day - 1]) · "
            + "\(M.hmString(startTime))—\(M.hmString(endTime))\n共 \(app.persons.count) 人 · "
            + "\(hasCourse) 人有课 · 实际占用合计 \(M.durationText(totalOverlap))"
    }
}
