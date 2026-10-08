import SwiftUI
import UniformTypeIdentifiers

/* =========================================================
   成员管理：按班级分组查看、新增成员、删除成员、按人导入课表
   （对标安卓 MemberDialog）。
   ========================================================= */

struct MemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var app = AppState.shared

    private static let grades = [2025, 2026, 2027, 2028, 2029, 2030]
    private static let classes = ["1班", "2班", "3班"]

    @State private var newName = ""
    @State private var grade = 2025
    @State private var klass = 0

    @State private var toDelete: Person? = nil
    @State private var importTarget: Person? = nil
    @State private var showImporter = false
    @State private var pendingCourses: [Course] = []
    @State private var showImportConfirm = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    Section {
                        HStack {
                            Text("年级").font(.subheadline)
                            Spacer()
                            Menu("\(String(grade))级") {
                                ForEach(Self.grades, id: \.self) { g in
                                    Button("\(String(g)) 级") { grade = g }
                                }
                            }
                            Menu(Self.classes[klass]) {
                                ForEach(0..<Self.classes.count, id: \.self) { i in
                                    Button(Self.classes[i]) { klass = i }
                                }
                            }
                        }
                        TextField("成员姓名", text: $newName)
                        Button {
                            addMember()
                        } label: {
                            Text("添加成员").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .liquidGlass(cornerRadius: 12)
                        .buttonStyle(.plain)
                    } header: {
                        Text("新增成员")
                    } footer: {
                        Text("班级形如 \(String(grade))级\(Self.classes[klass])，"
                             + "当前共 \(app.persons.count) 人")
                    }

                    Section("成员列表") {
                        if app.persons.isEmpty {
                            Text("暂时没有成员，请在上方添加。")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        ForEach(Array(groupInfo.enumerated()), id: \.offset) { _, g in
                            Text("\(g.name)　\(g.range.count) 人")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            ForEach(Array(g.range), id: \.self) { i in
                                memberRow(app.persons[i])
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("成员管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Import.xlsxTypes) { result in
            handlePicked(result)
        }
        .alert("删除成员？", isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } })) {
            Button("取消", role: .cancel) { toDelete = nil }
            Button("删除", role: .destructive) { confirmDelete() }
        } message: {
            if let p = toDelete {
                Text("确定删除「\(p.name)（\(p.cls)）」吗？\n\n该成员的全部课表也会一起删除，且会同步到云端。")
            }
        }
        .alert("导入课表", isPresented: $showImportConfirm) {
            Button("取消", role: .cancel) { pendingCourses = []; importTarget = nil }
            Button("替换") { applyImport() }
        } message: {
            if let p = importTarget {
                Text("已识别 \(pendingCourses.count) 条课程记录。\n\n"
                     + "确定用该文件替换「\(p.name)」现有课表吗？")
            }
        }
    }

    /* ================= 一行成员 ================= */

    /// 班级分组（已按班级+姓名排序后，同班必然连续）
    private var groupInfo: [(name: String, range: Range<Int>)] {
        let groups = M.classGroups(app.persons)
        let ranges = M.classRanges(app.persons)
        return zip(groups, ranges).map { ($0, $1.0..<$1.1) }
    }

    private func memberRow(_ p: Person) -> some View {
        HStack(spacing: 8) {
            Text(p.name).font(.subheadline.weight(.semibold))
            Text("\(p.courses.count) 门课程").font(.caption2).foregroundColor(.secondary)
            Spacer()
            Button {
                importTarget = p
                showImporter = true
            } label: {
                Text("导入课表").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                toDelete = p
            } label: {
                Text("删除成员").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    /* ================= 动作 ================= */

    private func addMember() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            app.showToast("请输入成员姓名")
            return
        }
        let cls = "\(String(grade))级\(Self.classes[klass])"
        for p in app.persons where p.name == name && p.cls == cls {
            app.showToast("该成员已经存在")
            return
        }
        let p = Person()
        p.name = name
        p.cls = cls
        app.persons.append(p)
        M.sortPersons(&app.persons)
        newName = ""
        app.saveData("已添加 \(name)（\(cls)）") {
            // 失败回滚
            AppState.shared.persons.removeAll { $0 === p }
            AppState.shared.poke()
        }
    }

    private func confirmDelete() {
        guard let p = toDelete else { return }
        if app.persons.count <= 1 {
            app.showToast("至少需要保留一名成员")
            toDelete = nil
            return
        }
        guard let idx = app.persons.firstIndex(where: { $0 === p }) else { toDelete = nil; return }
        app.persons.remove(at: idx)
        app.poke()
        toDelete = nil
        app.saveData("已删除成员 \(p.name)") {
            AppState.shared.persons.insert(p, at: min(idx, AppState.shared.persons.count))
            M.sortPersons(&AppState.shared.persons)
            AppState.shared.poke()
        }
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        guard let target = importTarget else { return }
        switch result {
        case .failure:
            app.showToast("没有选择文件")
            importTarget = nil
        case .success(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Import.loadCourses(from: url)
                DispatchQueue.main.async {
                    if !r.error.isEmpty {
                        app.showToast("导入失败：\(r.error)")
                        importTarget = nil
                        return
                    }
                    if r.courses.isEmpty {
                        app.showToast("没有识别到有效课程，请确认是原始课表格式。")
                        importTarget = nil
                        return
                    }
                    _ = target
                    pendingCourses = r.courses
                    showImportConfirm = true
                }
            }
        }
    }

    private func applyImport() {
        guard let target = importTarget, !pendingCourses.isEmpty else { return }
        let old = target.courses
        target.courses = pendingCourses
        let n = pendingCourses.count
        pendingCourses = []
        showImportConfirm = false
        importTarget = nil
        app.poke()
        app.saveData("已导入 \(target.name) 的课表") {
            target.courses = old
            AppState.shared.poke()
        }
        app.showToast("已导入 \(n) 条课程")
    }
}
