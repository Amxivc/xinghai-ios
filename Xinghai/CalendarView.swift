import SwiftUI
import UniformTypeIdentifiers

struct CalendarView: View {
    @ObservedObject private var app = AppState.shared
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var selDay = M.todayIso()
    @State private var filter = 0        // 0 全部 / 1 已完成 / 2 未完成
    @State private var workSheet: WorkDraft? = nil
    @State private var shareItem: ShareItem? = nil
    @State private var showExport = false
    @State private var showImporter = false
    @State private var bulkMode = false
    @State private var pendingWorks: [WorkRow] = []
    @State private var pendingMonths: [String] = []
    @State private var showImportConfirm = false

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
                segmentBar
                Divider().padding(.vertical, 6)
                dayList
            }
        }
        .task { if app.persons.isEmpty { app.load() } }
        .sheet(item: $workSheet) { d in
            WorkFormSheet(draft: d)
        }
        .sheet(item: $shareItem) { si in
            ShareSheet(items: [si.url])
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(works: app.works) { url in
                shareItem = ShareItem(url: url)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Import.xlsxTypes) { result in
            handleImport(result)
        }
        .alert("导入工作表", isPresented: $showImportConfirm) {
            Button("取消", role: .cancel) {
                pendingWorks = []
                pendingMonths = []
            }
            Button("导入") { applyImport() }
        } message: {
            Text("已识别 \(pendingWorks.count) 条工作记录"
                 + (pendingMonths.isEmpty ? "" : "（涉及 \(pendingMonths.joined(separator: "、"))）")
                 + "。\n\n导入的记录会追加到现有工作表并同步到云端。")
        }
    }

    /* ================= 月份导航 ================= */

    private var navBar: some View {
        HStack(spacing: 8) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Menu {
                ForEach(M.workYears(Calendar.current.component(.year, from: Date()),
                                    works: app.works), id: \.self) { y in
                    Menu("\(String(y)) 年") {
                        ForEach(1...12, id: \.self) { m in
                            Button("\(m) 月") {
                                year = y
                                month = m
                            }
                        }
                    }
                }
                Divider()
                if app.isAdmin {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入工作表", systemImage: "square.and.arrow.down")
                    }
                }
                Button {
                    showExport = true
                } label: {
                    Label("导出工作表（xlsx）", systemImage: "square.and.arrow.up")
                }
                if app.isAdmin {
                    Button {
                        setBulk(!bulkMode)
                    } label: {
                        Label(bulkMode ? "退出批量选择" : "批量选择",
                              systemImage: bulkMode ? "xmark.circle" : "checkmark.circle")
                    }
                }
            } label: {
                Text("\(String(year)) 年 \(month) 月").font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule()
            }
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Divider().frame(height: 18)
            if app.isAdmin {
                Button {
                    workSheet = WorkDraft.blank(year: year, month: month)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                Divider().frame(height: 18)
            }
            Button("今天") {
                let c = Calendar.current.dateComponents([.year, .month], from: Date())
                year = c.year ?? year
                month = c.month ?? month
                selDay = M.todayIso()
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlassCapsule()
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
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

    /* ================= 导入 / 批量 ================= */

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            app.showToast("没有选择文件")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Import.loadWorks(from: url)
            DispatchQueue.main.async {
                if !r.error.isEmpty {
                    app.showToast("导入失败：\(r.error)")
                    return
                }
                pendingWorks = r.rows
                pendingMonths = r.months
                showImportConfirm = true
            }
        }
    }

    private func applyImport() {
        guard !pendingWorks.isEmpty else { return }
        let added = pendingWorks
        app.works.append(contentsOf: added)
        let n = added.count
        pendingWorks = []
        pendingMonths = []
        showImportConfirm = false
        app.poke()
        app.saveData("已导入 \(n) 条工作记录") {
            AppState.shared.works.removeAll { w in added.contains { $0 === w } }
            AppState.shared.poke()
        }
    }

    private func setBulk(_ on: Bool) {
        bulkMode = on
        if !on { for r in app.works { r.selected = false } }
        app.poke()
    }

    /// 当前列表显示的记录（同筛选、同日期），与安卓 shownRows 口径一致
    private func shownIndices() -> [(Int, WorkRow)] {
        var out: [(Int, WorkRow)] = []
        for (i, r) in app.works.enumerated() where M.workDate(r) == selDay && r.hasContent {
            if filter == 0 { out.append((i, r)) }
            else if filter == 1 && r.done { out.append((i, r)) }
            else if filter == 2 && !r.done { out.append((i, r)) }
        }
        return out
    }

    private func toggleSelectAll() {
        let shown = shownIndices()
        if shown.isEmpty {
            app.showToast("当前没有可选择的记录")
            return
        }
        let all = shown.allSatisfy { $0.1.selected }
        for (_, r) in shown { r.selected = !all }
        app.poke()
    }

    private func deleteSelected() {
        let picked = app.works.filter { $0.selected }
        if picked.isEmpty {
            app.showToast("请先勾选要删除的工作记录")
            return
        }
        var removed: [(Int, WorkRow)] = []
        for r in picked {
            if let at = app.works.firstIndex(where: { $0 === r }) {
                removed.append((at, r))
            }
        }
        removed.sort { $0.0 > $1.0 }   // 从后往前删，下标不失效
        for (at, _) in removed { app.works.remove(at: at) }
        app.poke()
        let n = picked.count
        app.saveData("已删除 \(n) 条工作记录") {
            for (at, r) in removed.sorted(by: { $0.0 < $1.0 }) {
                AppState.shared.works.insert(r, at: min(at, AppState.shared.works.count))
            }
            AppState.shared.poke()
        }
        setBulk(false)
    }

    /* ================= 月历网格 ================= */

    private var monthGrid: some View {
        let daysInMonth = M.daysInMonth(year: year, month: month)
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

    /* ================= 分段筛选 ================= */

    private var segmentBar: some View {
        Picker("筛选", selection: $filter) {
            Text("全部").tag(0)
            Text("已完成").tag(1)
            Text("未完成").tag(2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /* ================= 选中日列表 ================= */

    private var dayList: some View {
        let list = shownIndices()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(M.formatCn(selDay)).font(.subheadline.weight(.medium))
                Spacer()
                Text("共 \(list.count) 项")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            if bulkMode { bulkBar(list) }

            if list.isEmpty {
                Text(filter == 0 ? "当天暂无工作安排" : "没有符合条件的记录")
                    .font(.footnote).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(list, id: \.0) { pair in
                    Button {
                        if bulkMode {
                            pair.1.selected.toggle()
                            app.poke()
                        } else {
                            tapWork(pair.0)
                        }
                    } label: {
                        workCard(pair.1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 20)
    }

    /// 批量操作条：全选当前显示 / 删除所选（对标安卓 bulkBar）
    private func bulkBar(_ list: [(Int, WorkRow)]) -> some View {
        let n = app.works.filter { $0.selected }.count
        let sel = list.filter { $0.1.selected }.count
        return HStack(spacing: 10) {
            Button {
                toggleSelectAll()
            } label: {
                Text(!list.isEmpty && sel == list.count ? "取消全选" : "全选当前显示")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray6))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                deleteSelected()
            } label: {
                Text(n > 0 ? "删除所选 \(n) 条" : "删除所选")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private func tapWork(_ idx: Int) {
        guard app.isAdmin else {
            app.showToast("请使用管理员账号登录后编辑")
            return
        }
        guard app.works.indices.contains(idx) else { return }
        workSheet = WorkDraft.from(workIdx: idx, row: app.works[idx],
                                   year: year, month: month)
    }

    private func workCard(_ r: WorkRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if bulkMode {
                    Image(systemName: r.selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundColor(r.selected ? .blue : .secondary)
                }
                Text(r.activity.isEmpty ? "（未填写活动）" : r.activity)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(r.statusText)
                    .font(.caption2)
                    .foregroundColor(r.done ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(r.done ? Color.green.opacity(0.12)
                                                      : Color.orange.opacity(0.12)))
                if app.isAdmin && !bulkMode {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundColor(.secondary)
                }
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

/* ================= 导出工作表：年份 + 月份多选 =================
   对标安卓 ExportDialog：选年份与若干月份，每月一张工作表，
   表头与文件命名和网页版逐字一致。
   ============================================================= */

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let works: [WorkRow]
    var onExport: (URL) -> Void

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var months: Set<Int> = [Calendar.current.component(.month, from: Date())]

    private var years: [Int] {
        M.workYears(Calendar.current.component(.year, from: Date()), works: works)
    }

    private var summary: String {
        let picked = months.sorted()
        if picked.isEmpty { return "尚未选择月份" }
        var total = 0
        for m in picked { total += M.exportableCount(year, m, works: works) }
        return "将导出 " + picked.map { "\($0)月" }.joined(separator: "、")
            + "，共 \(total) 条有效工作记录。"
    }

    private var canExport: Bool {
        !months.isEmpty && !Exporter.workSheets(year, months.sorted(), works: works).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("年份").font(.caption).foregroundColor(.secondary)
                            Menu {
                                ForEach(years, id: \.self) { y in
                                    Button("\(String(y)) 年") { year = y }
                                }
                            } label: {
                                HStack {
                                    Text("\(String(year)) 年").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(UIColor.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("月份（可多选）").font(.caption).foregroundColor(.secondary)
                            Button {
                                if months.count == 12 { months = [] }
                                else { months = Set(1...12) }
                            } label: {
                                Text(months.count == 12 ? "取消全选" : "全选 1—12 月")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color(UIColor.systemGray6))
                                    .foregroundColor(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5),
                                                     count: 6), spacing: 5) {
                                ForEach(1...12, id: \.self) { m in
                                    monthChip(m)
                                }
                            }
                        }

                        Text(summary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(16)
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Text("取消")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(UIColor.systemGray6))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        doExport()
                    } label: {
                        Text("开始导出")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canExport ? Color.blue : Color(UIColor.systemGray5))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canExport)
                }
                .padding(16)
            }
            .navigationTitle("导出工作表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func monthChip(_ m: Int) -> some View {
        let on = months.contains(m)
        return Button {
            if on { months.remove(m) } else { months.insert(m) }
        } label: {
            Text("\(m) 月")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(on ? Color.blue : Color.white)
                .foregroundColor(on ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(on ? Color.clear : Color(UIColor.systemGray5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func doExport() {
        let picked = months.sorted()
        guard !picked.isEmpty else { return }
        let sheets = Exporter.workSheets(year, picked, works: works)
        if sheets.isEmpty {
            AppState.shared.showToast("所选月份暂无有效工作记录")
            return
        }
        guard let url = Exporter.write(Exporter.workFileName(year, picked), sheets) else {
            AppState.shared.showToast("导出失败")
            return
        }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onExport(url) }
    }
}
