import SwiftUI

/* ================= 工具 ================= */

extension Course {
    func clone() -> Course {
        let c = Course()
        c.n = n; c.t = t; c.r = r; c.d = d; c.p = p; c.s = s; c.e = e
        c.w = w; c.timeMode = timeMode; c.customStart = customStart; c.customEnd = customEnd
        c.ws = ws
        return c
    }
    func copyFrom(_ o: Course) {
        n = o.n; t = o.t; r = o.r; d = o.d; p = o.p; s = o.s; e = o.e
        w = o.w; timeMode = o.timeMode; customStart = o.customStart; customEnd = o.customEnd
        ws = o.ws
    }
}

extension WorkRow {
    func clone() -> WorkRow {
        let r = WorkRow()
        r.id = id; r.date = date; r.name = name; r.activity = activity
        r.content = content; r.equipment = equipment; r.returnTime = returnTime
        r.setupTime = setupTime; r.completionTime = completionTime
        r.remark = remark; r.responsible = responsible; r.status = status
        return r
    }
    func copyFrom(_ o: WorkRow) {
        id = o.id; date = o.date; name = o.name; activity = o.activity
        content = o.content; equipment = o.equipment; returnTime = o.returnTime
        setupTime = o.setupTime; completionTime = o.completionTime
        remark = o.remark; responsible = o.responsible; status = o.status
    }
}

/* ================= 编辑器草稿 ================= */

struct CourseDraft: Identifiable {
    let id = UUID()
    var personIdx: Int
    var courseIdx: Int      // -1 = 新增
    var name = ""
    var teacher = ""
    var room = ""
    var day = 1
    var timeMode = 0        // 0 按节次  1 自定义时间
    var startP = 1
    var endP = 1
    var customStart = "09:00"
    var customEnd = "09:40"
    var weeks: Set<Int> = []

    /// 从已有课程构造
    static func from(personIdx: Int, courseIdx: Int, course: Course) -> CourseDraft {
        var d = CourseDraft(personIdx: personIdx, courseIdx: courseIdx)
        d.name = course.n
        d.teacher = course.t == "—" ? "" : course.t
        d.room = course.r == "—" ? "" : course.r
        d.day = max(1, min(7, course.d))
        d.timeMode = course.timeMode == "custom" ? 1 : 0
        d.startP = max(1, course.s)
        d.endP = max(d.startP, course.e)
        d.customStart = course.customStart.isEmpty ? "09:00" : course.customStart
        d.customEnd = course.customEnd.isEmpty ? "09:40" : course.customEnd
        d.weeks = M.parseWeeks(course.w)
        return d
    }

    /// 点空白格快速新增：预填星期与节次
    static func preset(personIdx: Int, day: Int, section: Int) -> CourseDraft {
        var d = CourseDraft(personIdx: personIdx, courseIdx: -1)
        d.day = max(1, min(7, day))
        d.startP = max(1, min(M.periods.count, section))
        d.endP = min(M.periods.count, d.startP + 1)
        d.weeks = [M.currentWeek]
        return d
    }
}

/* ================= 课程编辑器 ================= */

struct CourseEditorSheet: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss
    let draft: CourseDraft

    @State private var name: String
    @State private var teacher: String
    @State private var room: String
    @State private var day: Int
    @State private var timeMode: Int
    @State private var startP: Int
    @State private var endP: Int
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var weeks: Set<Int>
    @State private var errMsg: String? = nil
    @State private var showDelete = false

    init(draft: CourseDraft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
        _teacher = State(initialValue: draft.teacher)
        _room = State(initialValue: draft.room)
        _day = State(initialValue: draft.day)
        _timeMode = State(initialValue: draft.timeMode)
        _startP = State(initialValue: draft.startP)
        _endP = State(initialValue: draft.endP)
        _customStart = State(initialValue: M.hmToDate(draft.customStart))
        _customEnd = State(initialValue: M.hmToDate(draft.customEnd))
        _weeks = State(initialValue: draft.weeks)
    }

    private var person: Person? {
        app.persons.indices.contains(draft.personIdx) ? app.persons[draft.personIdx] : nil
    }

    var body: some View {
        NavigationView {
            Form {
                basicSection
                daySection
                timeSection
                weekSection
                if draft.courseIdx >= 0 {
                    Section {
                        Button("删除这门课程", role: .destructive) { showDelete = true }
                    }
                }
                if let e = errMsg {
                    Section {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(draft.courseIdx < 0 ? "新增课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("删除课程", isPresented: $showDelete) {
                Button("删除", role: .destructive) { deleteCourse() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确定删除「\(name)」吗？该课程的所有周次安排会一起删除，并同步到云端。")
            }
        }
        .navigationViewStyle(.stack)
    }

    /* ---------- 基本信息 ---------- */

    private var basicSection: some View {
        Section("基本信息") {
            TextField("课程名称（必填，如：中国音乐史）", text: $name)
            TextField("任课教师（如：李子林）", text: $teacher)
            TextField("上课教室（如：C210）", text: $room)
        }
    }

    /* ---------- 星期 ---------- */

    private var daySection: some View {
        Section("星期") {
            HStack(spacing: 5) {
                ForEach(1...7, id: \.self) { d in
                    Button {
                        day = d
                    } label: {
                        Text(String(M.days[d - 1].dropFirst()))
                            .font(.system(size: 13, weight: day == d ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(day == d ? Color.blue
                                      : Color(UIColor.tertiarySystemFill)))
                            .foregroundColor(day == d ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /* ---------- 上课时间 ---------- */

    private var timeSection: some View {
        Section("上课时间") {
            Picker("模式", selection: $timeMode) {
                Text("按节次").tag(0)
                Text("自定义时间").tag(1)
            }
            .pickerStyle(.segmented)
            if timeMode == 0 {
                Picker("起始节次", selection: $startP) {
                    ForEach(1...M.periods.count, id: \.self) { p in
                        Text(periodText(p)).tag(p)
                    }
                }
                Picker("结束节次", selection: $endP) {
                    ForEach(startP...M.periods.count, id: \.self) { p in
                        Text(periodText(p)).tag(p)
                    }
                }
                .onChange(of: startP) { nv in
                    if endP < nv { endP = nv }
                }
            } else {
                DatePicker("开始时间", selection: $customStart, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $customEnd, displayedComponents: .hourAndMinute)
                Text("自定义时间会按学校节次表折算成占用的小节，用于课表排序与冲突判断。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /* ---------- 上课周次 ---------- */

    private var weekSection: some View {
        Section("上课周次") {
            HStack {
                Button("全选") { weeks = Set(1...M.TOTAL_WEEKS) }
                Spacer()
                Button("清空") { weeks = [] }
            }
            .font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7),
                      spacing: 6) {
                ForEach(1...M.TOTAL_WEEKS, id: \.self) { w in
                    Button {
                        if weeks.contains(w) { weeks.remove(w) } else { weeks.insert(w) }
                    } label: {
                        Text("\(w)")
                            .font(.system(size: 12, weight: weeks.contains(w) ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(weeks.contains(w) ? Color.blue
                                      : Color(UIColor.tertiarySystemFill)))
                            .foregroundColor(weeks.contains(w) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(weeks.isEmpty ? "尚未选择周次"
                 : "已选 \(weeks.count) 周：\(M.compressWeeks(weeks))")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /* ---------- 保存 / 删除 ---------- */

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { errMsg = "请填写课程名称"; return }
        if weeks.isEmpty { errMsg = "请至少选择一个周次"; return }
        let w = M.compressWeeks(weeks)

        let c = Course()
        c.n = n
        c.t = emptyDash(teacher)
        c.r = emptyDash(room)
        c.d = day
        if timeMode == 0 {
            if endP < startP { errMsg = "结束节次不能早于起始节次"; return }
            c.s = startP
            c.e = endP
            c.timeMode = "period"
            c.w = w
        } else {
            let a = M.normalizeClock(hm(customStart))
            let b = M.normalizeClock(hm(customEnd))
            if a.isEmpty || b.isEmpty || M.clockMinutes(b) <= M.clockMinutes(a) {
                errMsg = "自定义时间不正确，结束时间必须晚于开始时间"
                return
            }
            c.timeMode = "custom"
            c.customStart = a
            c.customEnd = b
            c.s = M.sectionFor(a, false)
            c.e = max(c.s, M.sectionFor(b, true))
            c.w = w
        }
        M.normalize(c)

        guard let person = person else { errMsg = "成员数据已变化，请重试"; return }
        if draft.courseIdx < 0 {
            person.courses.append(c)
            app.poke()
            dismiss()
            app.saveData("已新增课程「\(c.n)」") {
                person.courses.removeAll { $0 === c }
                AppState.shared.poke()
            }
        } else {
            guard person.courses.indices.contains(draft.courseIdx) else {
                errMsg = "课程数据已变化，请重试"
                return
            }
            let origin = person.courses[draft.courseIdx]
            let backup = origin.clone()
            origin.copyFrom(c)
            app.poke()
            dismiss()
            app.saveData("已保存课程修改") {
                origin.copyFrom(backup)
                AppState.shared.poke()
            }
        }
    }

    private func deleteCourse() {
        guard let person = person,
              person.courses.indices.contains(draft.courseIdx) else { return }
        let origin = person.courses[draft.courseIdx]
        let at = draft.courseIdx
        person.courses.remove(at: at)
        app.poke()
        dismiss()
        app.saveData("已删除课程") {
            person.courses.insert(origin, at: min(at, person.courses.count))
            AppState.shared.poke()
        }
    }

    /* ---------- 小工具 ---------- */

    private func periodText(_ p: Int) -> String {
        let r = M.timeRange(p, p)
        return "第\(M.cn(p))节" + (r.isEmpty ? "" : "（\(r)）")
    }

    private func emptyDash(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "—" : t
    }

    private func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0)
    }
}
