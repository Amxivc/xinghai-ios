import SwiftUI
import UniformTypeIdentifiers

struct TimetableView: View {
    @ObservedObject private var app = AppState.shared
    @State private var week = M.currentWeek
    /// 按日期跳转后聚焦的星期几（0 = 不聚焦）
    @State private var pickedDay = 0
    @State private var personIdx = 0
    @State private var activeSheet: TSheet? = nil
    @State private var shareItem: ShareItem? = nil
    @State private var showJump = false
    @State private var showMembers = false
    @State private var showTimeSearch = false
    @State private var showImporter = false
    @State private var pendingCourses: [Course] = []
    @State private var showImportConfirm = false

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
        .sheet(isPresented: $showJump) {
            JumpSheet(week: $week, pickedDay: $pickedDay)
        }
        .sheet(isPresented: $showMembers) {
            MemberSheet()
        }
        .sheet(isPresented: $showTimeSearch) {
            TimeSearchSheet()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Import.xlsxTypes) { result in
            guard case .success(let url) = result else {
                app.showToast("没有选择文件")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Import.loadCourses(from: url)
                DispatchQueue.main.async {
                    if !r.error.isEmpty {
                        app.showToast("导入失败：\(r.error)")
                    } else if r.courses.isEmpty {
                        app.showToast("没有识别到有效课程，请确认是原始课表格式。")
                    } else {
                        pendingCourses = r.courses
                        showImportConfirm = true
                    }
                }
            }
        }
        .alert("导入课表", isPresented: $showImportConfirm) {
            Button("取消", role: .cancel) { pendingCourses = [] }
            Button("替换") { applyImport() }
        } message: {
            Text("已识别 \(pendingCourses.count) 条课程记录。\n\n"
                 + "确定用该文件替换「\(person?.name ?? "当前成员")」现有课表吗？")
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
                pickedDay = 0
            } label: {
                Image(systemName: "chevron.left").font(.body)
            }
            .buttonStyle(.borderless)

            // 点标题：显示周次 / 按日期定位
            Button {
                showJump = true
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
            .buttonStyle(.plain)

            Button {
                if week < M.TOTAL_WEEKS { week += 1 }
                pickedDay = 0
            } label: {
                Image(systemName: "chevron.right").font(.body)
            }
            .buttonStyle(.borderless)

            Button("今天") {
                week = M.currentWeek
                pickedDay = M.todayDay()
            }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .buttonStyle(.plain)

            Spacer()

            // 操作表：新增课程 / 导入课表 / 成员管理 / 时间查找 / 导出
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
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入课表", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showMembers = true
                    } label: {
                        Label("成员管理", systemImage: "person.2")
                    }
                }
                Button {
                    showTimeSearch = true
                } label: {
                    Label("时间查找", systemImage: "clock")
                }
                Button {
                    exportXlsx()
                } label: {
                    Label("导出该成员课表（xlsx）", systemImage: "square.and.arrow.up")
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

    private func exportXlsx() {
        guard let p = person else { return }
        let sheets = Exporter.timetableSheets([p])
        if let url = Exporter.write(Exporter.timetableFileName([p]), sheets) {
            shareItem = ShareItem(url: url)
        } else {
            app.showToast("导出失败")
        }
    }

    /// 用导入的课程替换当前成员课表（保存失败回滚）
    private func applyImport() {
        guard let p = person, !pendingCourses.isEmpty else { return }
        let old = p.courses
        let n = pendingCourses.count
        p.courses = pendingCourses
        pendingCourses = []
        showImportConfirm = false
        app.poke()
        app.saveData("已导入 \(n) 条课程") {
            p.courses = old
            AppState.shared.poke()
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
        let isPicked = (day == pickedDay)
        return VStack(spacing: gap) {
            Text(M.days[day - 1])
                .font(.system(size: 11, weight: (isToday || isPicked) ? .bold : .regular))
                .foregroundColor(isPicked ? .white : (isToday ? .blue : .secondary))
                .frame(width: colW, height: 18)
                .background(isPicked ? Color.blue : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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

/* ================= 跳转到：显示周次 / 按日期定位 =================
   对标安卓 TimetablePage.pickWeekOrDate（🗓 显示周次 · 📅 选择具体日期），
   iOS 上合成一页，日期跳转后高亮所在当天。
   ============================================================= */

struct JumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var week: Int
    @Binding var pickedDay: Int
    @State private var date = Date()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        Text("按日期定位").font(.subheadline.weight(.semibold))
                        Spacer()
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                    }
                    Button {
                        jumpToDate()
                    } label: {
                        Text("跳到这一天")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .liquidGlass(cornerRadius: 12)
                    .buttonStyle(.plain)

                    Text("不在本学期第 1—\(M.TOTAL_WEEKS) 周范围内的日期无法跳转。")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)

                Divider()

                List {
                    ForEach(1...M.TOTAL_WEEKS, id: \.self) { w in
                        Button {
                            week = w
                            pickedDay = 0
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("第 \(w) 周" + (w == M.currentWeek ? "（本周）" : ""))
                                        .font(.subheadline)
                                    Text("\(M.weekDate(w, 1)) ~ \(M.weekDate(w, 7))")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if w == week {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("跳转到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func jumpToDate() {
        let iso = M.dateToIso(date)
        guard let sd = M.semesterOf(iso) else {
            AppState.shared.showToast("\(M.formatCn(iso)) 不在本学期第 1—\(M.TOTAL_WEEKS) 周范围内")
            return
        }
        week = sd.week
        pickedDay = sd.day
        AppState.shared.showToast("已跳到第 \(sd.week) 周 · \(M.days[sd.day - 1])")
        dismiss()
    }
}
