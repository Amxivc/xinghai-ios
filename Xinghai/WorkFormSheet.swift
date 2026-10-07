import SwiftUI

/* ================= 工作草稿 ================= */

struct WorkDraft: Identifiable {
    let id = UUID()
    var workIdx: Int         // -1 = 新增
    var contextYear: Int
    var contextMonth: Int
    var name = ""
    var activity = ""
    var content = ""
    var equipment = ""
    var responsible = ""
    var remark = ""
    var setupTime = ""       // yyyy-MM-dd 或空
    var returnTime = ""
    var completionTime = ""

    static func from(workIdx: Int, row: WorkRow, year: Int, month: Int) -> WorkDraft {
        var d = WorkDraft(workIdx: workIdx, contextYear: year, contextMonth: month)
        d.name = row.name
        d.activity = row.activity
        d.content = row.content
        d.equipment = row.equipment
        d.responsible = row.responsible
        d.remark = row.remark
        d.setupTime = nz(row.setupTime)
        d.returnTime = nz(row.returnTime)
        d.completionTime = nz(row.completionTime)
        return d
    }

    static func blank(year: Int, month: Int) -> WorkDraft {
        WorkDraft(workIdx: -1, contextYear: year, contextMonth: month)
    }

    private static func nz(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > 10 ? String(t.prefix(10)) : t
    }
}

/* ================= 工作表单 ================= */

struct WorkFormSheet: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss
    let draft: WorkDraft

    @State private var name: String
    @State private var activity: String
    @State private var content: String
    @State private var equipment: String
    @State private var responsible: String
    @State private var remark: String
    @State private var setupTime: String
    @State private var returnTime: String
    @State private var completionTime: String
    @State private var errMsg: String? = nil
    @State private var showDelete = false

    init(draft: WorkDraft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
        _activity = State(initialValue: draft.activity)
        _content = State(initialValue: draft.content)
        _equipment = State(initialValue: draft.equipment)
        _responsible = State(initialValue: draft.responsible)
        _remark = State(initialValue: draft.remark)
        _setupTime = State(initialValue: draft.setupTime)
        _returnTime = State(initialValue: draft.returnTime)
        _completionTime = State(initialValue: draft.completionTime)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("姓名（如：张三）", text: $name)
                    TextField("活动名称（如：迎新晚会）", text: $activity)
                    TextField("工作内容（这次做了哪些事）", text: $content)
                    TextField("摄影设备名称（如：索尼 A7M4 ×1）", text: $equipment)
                    TextField("负责人（如：李四）", text: $responsible)
                }
                timeSection
                Section("备注") {
                    TextField("补充说明", text: $remark)
                }
                if draft.workIdx >= 0 {
                    Section {
                        Button("删除这条记录", role: .destructive) { showDelete = true }
                    }
                }
                if let e = errMsg {
                    Section {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(draft.workIdx < 0 ? "新增工作" : "修改工作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("删除工作记录", isPresented: $showDelete) {
                Button("删除", role: .destructive) { deleteWork() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确定删除这条工作记录吗？删除后会同步到云端。")
            }
        }
        .navigationViewStyle(.stack)
    }

    /* ---------- 时间节点 ---------- */

    private var timeSection: some View {
        Section("时间节点") {
            WorkDateRow(label: "布置时间", iso: $setupTime)
            WorkDateRow(label: "归还时间", iso: $returnTime)
            WorkDateRow(label: "完成时间", iso: $completionTime)
            Text("填了「完成时间」即视为已完成，可在台历里按完成情况筛选。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /* ---------- 保存 / 删除 ---------- */

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let a = activity.trimmingCharacters(in: .whitespaces)
        let c = content.trimmingCharacters(in: .whitespaces)
        if n.isEmpty && a.isEmpty && c.isEmpty {
            errMsg = "请至少填写姓名、活动名称或工作内容"
            return
        }

        let isNew = draft.workIdx < 0
        let target: WorkRow
        let backup: WorkRow?
        if isNew {
            target = WorkRow()
            target.id = "work-" + String(Int(Date().timeIntervalSince1970 * 1000))
                + "-" + String(format: "%06x", Int.random(in: 0..<0xffffff))
            target.date = String(format: "%04d-%02d-01", draft.contextYear, draft.contextMonth)
            backup = nil
            app.works.append(target)
        } else {
            guard app.works.indices.contains(draft.workIdx) else {
                errMsg = "记录已变化，请重试"
                return
            }
            target = app.works[draft.workIdx]
            backup = target.clone()
        }

        target.name = n
        target.activity = a
        target.content = c
        target.equipment = equipment.trimmingCharacters(in: .whitespaces)
        target.responsible = responsible.trimmingCharacters(in: .whitespaces)
        target.setupTime = setupTime
        target.returnTime = returnTime
        target.completionTime = completionTime
        target.remark = remark.trimmingCharacters(in: .whitespaces)
        if isNew {
            target.status = target.done ? "已完成" : "未完成"
        } else {
            // 完成时间被清空时同步修正状态，避免「已完成但没有完成时间」的矛盾
            if target.completionTime.isEmpty && target.status == "已完成" {
                target.status = "未完成"
            } else if !target.completionTime.isEmpty && target.status.isEmpty {
                target.status = "已完成"
            }
        }

        app.poke()
        dismiss()
        app.saveData(isNew ? "已新增工作" : "已保存工作修改") {
            if isNew {
                AppState.shared.works.removeAll { $0 === target }
            } else if let b = backup {
                target.copyFrom(b)
            }
            AppState.shared.poke()
        }
    }

    private func deleteWork() {
        guard app.works.indices.contains(draft.workIdx) else { return }
        let row = app.works[draft.workIdx]
        let at = draft.workIdx
        app.works.remove(at: at)
        app.poke()
        dismiss()
        app.saveData("已删除工作记录") {
            AppState.shared.works.insert(row, at: min(at, AppState.shared.works.count))
            AppState.shared.poke()
        }
    }
}

/* ================= 日期行（点选 / 清空） ================= */

struct WorkDateRow: View {
    let label: String
    @Binding var iso: String
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    editing.toggle()
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
                        Spacer()
                        Text(iso.isEmpty ? "未设置" : iso)
                            .foregroundColor(iso.isEmpty ? .secondary : .primary)
                    }
                }
                .buttonStyle(.plain)
                if !iso.isEmpty {
                    Button("清空") { iso = "" }
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            if editing {
                DatePicker("", selection: Binding(
                    get: { M.isoToDate(iso) },
                    set: { iso = M.dateToIso($0); editing = false }
                ), displayedComponents: .date)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
            }
        }
    }
}
