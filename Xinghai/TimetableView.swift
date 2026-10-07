import SwiftUI

struct TimetableView: View {
    @ObservedObject private var app = AppState.shared
    @State private var week = M.currentWeek
    @State private var personIdx = 0
    @State private var activeSheet: TSheet? = nil
    @State private var shareItem: ShareItem? = nil

    private var person: Person? {
        if app.persons.indices.contains(personIdx) {
            return app.persons[personIdx]
        }
        return app.persons.isEmpty ? nil : app.persons[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let b = app.banner {
                BannerView(text: b)
            }
            header
            Divider()
            if app.persons.isEmpty {
                Spacer()
                if app.loading {
                    ProgressView("同步云端数据…")
                } else {
                    Text("暂无数据").foregroundColor(.secondary)
                }
                Spacer()
            } else {
                weekGrid
            }
        }
        .task { if app.persons.isEmpty { app.load() } }
        .sheet(item: $activeSheet) { s in
            sheetView(s)
        }
        .sheet(item: $shareItem) { si in
            ShareSheet(items: [si.url])
        }
    }

    /* ================= 弹窗路由 ================= */

    enum TSheet: Identifiable {
        case detail(personIdx: Int, courseIdx: Int)
        case editor(CourseDraft)

        var id: String {
            switch self {
            case .detail(let p, let c): return "d-\(p)-\(c)"
            case .editor(let d): return "e-\(d.id.uuidString)"
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ s: TSheet) -> some View {
        switch s {
        case .detail(let p, let c):
            CourseDetailSheet(personIdx: p, courseIdx: c) { draft in
                activeSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    activeSheet = .editor(draft)
                }
            }
        case .editor(let d):
            CourseEditorSheet(draft: d)
        }
    }

    /* ================= 顶部导航 ================= */

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if week > 1 { week -= 1 }
            } label: {
                Image(systemName: "chevron.left").font(.body)
            }
            .buttonStyle(.borderless)

            // 点标题直选周次
            Menu {
                ForEach(1...M.TOTAL_WEEKS, id: \.self) { w in
                    Button(w == M.currentWeek ? "第 \(w) 周（本周）" : "第 \(w) 周") {
                        week = w
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Text("第 \(week) 周").font(.headline)
                    Text("\(M.weekDate(week, 1)) ~ \(M.weekDate(week, 7))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .liquidGlass(cornerRadius: 14)
            }

            Button {
                if week < M.TOTAL_WEEKS { week += 1 }
            } label: {
                Image(systemName: "chevron.right").font(.body)
            }
            .buttonStyle(.borderless)

            Button("今天") { week = M.currentWeek }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .buttonStyle(.plain)

            Spacer()

            // 操作表：新增课程 / 导出
            Menu {
                if app.isAdmin {
                    Button {
                        if let p = person, let idx = app.persons.firstIndex(where: { $0 === p }) {
                            activeSheet = .editor(CourseDraft.preset(personIdx: idx,
                                                                     day: 1, section: 1))
                        }
                    } label: {
                        Label("新增课程", systemImage: "plus.circle")
                    }
                }
                Button {
                    exportCsv()
                } label: {
                    Label("导出该成员课表（CSV）", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }

            // 成员选择（按班级分组）
            Menu {
                ForEach(classOrder(), id: \.self) { cls in
                    Section(cls.isEmpty ? "未分班" : cls) {
                        ForEach(app.persons.indices.filter { app.persons[$0].cls == cls },
                                id: \.self) { i in
                            Button {
                                personIdx = i
                            } label: {
                                if i == personIdx {
                                    Label(app.persons[i].name.isEmpty ? "（未命名）" : app.persons[i].name,
                                          systemImage: "checkmark")
                                } else {
                                    Text(app.persons[i].name.isEmpty ? "（未命名）" : app.persons[i].name)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(person?.name ?? "选择成员").lineLimit(1)
                    Image(systemName: "chevron.down")
                }
                .font(.subheadline)
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func classOrder() -> [String] {
        var seen: [String] = []
        for p in app.persons where !seen.contains(p.cls) {
            seen.append(p.cls)
        }
        return seen
    }

    private func exportCsv() {
        guard let p = person else { return }
        let (name, lines) = Exporter.timetableCsv(p)
        if let url = Exporter.writeCsv(name, lines) {
            shareItem = ShareItem(url: url)
        } else {
            app.showToast("导出失败")
        }
    }

    /* ================= 周网格 ================= */

    private var weekGrid: some View {
        GeometryReader { geo in
            let axisW: CGFloat = 34
            let gap: CGFloat = 2
            let rowH: CGFloat = 56
            let colW = max(36, (geo.size.width - axisW - gap * 8 - 12) / 7)
            ScrollView {
                HStack(alignment: .top, spacing: gap) {
                    // 左侧时间轴
                    VStack(spacing: gap) {
                        Text("").frame(height: 18)
                        ForEach(1...M.periods.count, id: \.self) { p in
                            VStack(spacing: 0) {
                                Text("\(p)")
                                    .font(.system(size: 10, weight: .medium))
                                Text(M.periods[p - 1][1])
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: axisW, height: rowH)
                        }
                    }
                    ForEach(1...7, id: \.self) { day in
                        dayColumn(day, colW: colW, rowH: rowH, gap: gap)
                    }
                }
                .padding(6)
            }
        }
    }

    private func dayColumn(_ day: Int, colW: CGFloat, rowH: CGFloat, gap: CGFloat) -> some View {
        let stride = rowH + gap
        var list: [(Int, Course)] = []
        if let p = person {
            for (i, c) in p.courses.enumerated() where c.d == day && c.inWeek(week) {
                list.append((i, c))
            }
        }
        let isToday = (day == M.todayDay && week == M.currentWeek)
        return VStack(spacing: gap) {
            Text(M.days[day - 1])
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundColor(isToday ? .blue : .secondary)
                .frame(width: colW, height: 18)
            ZStack(alignment: .topLeading) {
                // 空白格：管理员点击直接新增课程
                VStack(spacing: gap) {
                    ForEach(1...M.periods.count, id: \.self) { p in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(UIColor.systemGroupedBackground))
                            .frame(width: colW, height: rowH)
                            .contentShape(Rectangle())
                            .onTapGesture { tapEmpty(day: day, section: p) }
                    }
                }
                ForEach(list, id: \.0) { pair in
                    courseBlock(pair.1)
                        .frame(width: colW,
                               height: rowH * CGFloat(pair.1.span) + gap * CGFloat(pair.1.span - 1),
                               alignment: .topLeading)
                        .offset(y: stride * CGFloat(pair.1.s - 1))
                        .contentShape(Rectangle())
                        .onTapGesture { tapCourse(pair.0) }
                }
            }
        }
    }

    private func tapEmpty(day: Int, section: Int) {
        guard app.isAdmin else {
            app.showToast("请使用管理员账号登录后编辑")
            return
        }
        guard let p = person, let idx = app.persons.firstIndex(where: { $0 === p }) else { return }
        activeSheet = .editor(CourseDraft.preset(personIdx: idx, day: day, section: section))
    }

    private func tapCourse(_ courseIdx: Int) {
        guard let p = person, let idx = app.persons.firstIndex(where: { $0 === p }) else { return }
        activeSheet = .detail(personIdx: idx, courseIdx: courseIdx)
    }

    private func courseBlock(_ c: Course) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.n)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(3)
                .minimumScaleFactor(0.55)
            if !c.r.isEmpty {
                Text(c.r)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(.secondary)
            }
            if !c.t.isEmpty {
                Text(c.t)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.color.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.color.opacity(0.55), lineWidth: 0.8))
    }
}

/* ================= 课程详情卡 ================= */

struct CourseDetailSheet: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss
    let personIdx: Int
    let courseIdx: Int
    var onEdit: (CourseDraft) -> Void

    @State private var showDelete = false

    private var person: Person? {
        app.persons.indices.contains(personIdx) ? app.persons[personIdx] : nil
    }

    private var course: Course? {
        guard let p = person, p.courses.indices.contains(courseIdx) else { return nil }
        return p.courses[courseIdx]
    }

    var body: some View {
        NavigationView {
            Group {
                if let c = course {
                    List {
                        Section {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(c.color.opacity(0.75))
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.n).font(.headline)
                                    if let p = person {
                                        Text(p.name + (p.cls.isEmpty ? "" : " · " + p.cls))
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Section("详细信息") {
                            InfoRow(label: "任课教师", value: c.t)
                            InfoRow(label: "上课教室", value: c.r)
                            InfoRow(label: "星期", value: M.days[max(0, min(6, c.d - 1))])
                            InfoRow(label: "节次", value: M.periodLabel(c.s, c.e))
                            InfoRow(label: "时间", value: M.courseRange(c))
                            InfoRow(label: "上课周次", value: c.w.isEmpty ? "—" : "第 " + c.w + " 周")
                        }
                        if app.isAdmin {
                            Section {
                                Button {
                                    onEdit(CourseDraft.from(personIdx: personIdx,
                                                            courseIdx: courseIdx,
                                                            course: c))
                                } label: {
                                    Label("编辑这门课程", systemImage: "pencil")
                                }
                                Button("删除这门课程", role: .destructive) {
                                    showDelete = true
                                }
                            }
                        } else {
                            Section {
                                Text("使用管理员账号登录后可编辑课程")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Text("课程不存在").foregroundColor(.secondary)
                }
            }
            .navigationTitle("课程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .confirmationDialog("删除课程", isPresented: $showDelete) {
                Button("删除", role: .destructive) { doDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                if let c = course {
                    Text("确定删除「\(c.n)」吗？该课程的所有周次安排会一起删除，并同步到云端。")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func doDelete() {
        guard let p = person, p.courses.indices.contains(courseIdx) else { return }
        let origin = p.courses[courseIdx]
        let at = courseIdx
        p.courses.remove(at: at)
        app.poke()
        dismiss()
        app.saveData("已删除课程") {
            p.courses.insert(origin, at: min(at, p.courses.count))
            AppState.shared.poke()
        }
    }
}
