import Foundation
import UniformTypeIdentifiers

/* =========================================================
   从 xlsx 里解析「原始课表」与「工作台历」，规则与安卓 CourseImport.java
   和网页版 parseImportedCell / importWorkbook 一致。
   ========================================================= */

enum Import {

    /// 选文件用：xlsx + 兜底任意文件（部分系统未注册 xlsx 扩展名）
    static var xlsxTypes: [UTType] {
        var t: [UTType] = []
        if let x = UTType(filenameExtension: "xlsx") { t.append(x) }
        if let x = UTType(filenameExtension: "xls") { t.append(x) }
        t.append(.data)
        return t
    }

    /// 解析文件为课表（同步，调用方自行放后台线程）
    static func loadCourses(from url: URL) -> (courses: [Course], error: String) {
        let needStop = url.startAccessingSecurityScopedResource()
        defer { if needStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return ([], "文件读取失败") }
        do {
            let book = try Xlsx.read(data)
            return (parseTimetable(book), "")
        } catch {
            return ([], (error as? XlsxError)?.msg ?? error.localizedDescription)
        }
    }

    /// 解析文件为工作台历（同步）
    static func loadWorks(from url: URL) -> (rows: [WorkRow], months: [String], error: String) {
        let needStop = url.startAccessingSecurityScopedResource()
        defer { if needStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return ([], [], "文件读取失败") }
        do {
            let book = try Xlsx.read(data)
            let wi = parseWorkCalendar(book)
            if wi.rows.isEmpty { return ([], [], "没有识别到有效记录") }
            return (wi.rows, wi.months, "")
        } catch {
            return ([], [], (error as? XlsxError)?.msg ?? error.localizedDescription)
        }
    }

    /* ================= 一、课表导入 =================
       原始课表格式：每张表里有若干「第X大节」行，行内每列是星期几的单元格；
       上方的「周次」行给出每列对应周次。单元格内多行文本形如：
           课程名 / 教师（可多行）/ 2-0102（开头数字是周次）/ 教室
       ================================================= */

    static func parseTimetable(_ book: Xlsx.Book) -> [Course] {
        var all: [Course] = []
        for rows in book.sheets {
            var weekByCol: [Int] = []
            var block = false
            for row in rows {
                if row.isEmpty { continue }
                let first = cell(row, 0).trimmingCharacters(in: .whitespaces)
                if first.contains("周次") {
                    block = true
                    weekByCol = [Int](repeating: 0, count: row.count)
                    var carry = 0
                    var c = 1
                    while c < row.count {
                        let v = cell(row, c).trimmingCharacters(in: .whitespaces)
                        if let m = regexMatch("第\\s*(\\d+)\\s*周", v),
                           let g = regexGroup(m, 1, v), let n = Int(g) {
                            carry = n
                            weekByCol[c] = carry
                        } else if c > 1 {
                            weekByCol[c] = carry
                        }
                        c += 1
                    }
                    continue
                }
                if !block { continue }
                guard let pm = regexMatch("^第\\s*(\\d+|[一二三四五六])\\s*大节", first),
                      let g = regexGroup(pm, 1, first) else { continue }
                let big = bigSection(g)
                var start = 1, end = 2
                if big >= 1 && big <= M.legacy.count {
                    start = M.legacy[big - 1][0]
                    end = M.legacy[big - 1][1]
                }
                var c = 1
                while c < row.count {
                    let txt = cell(row, c)
                    if txt.trimmingCharacters(in: .whitespaces).isEmpty { c += 1; continue }
                    let week = c < weekByCol.count ? weekByCol[c] : 0
                    if week > 0 {
                        let day = ((c - 1) % 7) + 1
                        all.append(contentsOf: parseCell(txt, fallbackWeek: week, day: day,
                                                         startSection: start, endSection: end))
                    }
                    c += 1
                }
            }
        }
        // 合并完全相同（课程名/教师/教室/星期/节次）的记录，周次取并集
        var order: [String] = []
        var weeksOf: [String: Set<Int>] = [:]
        var proto: [String: Course] = [:]
        for c in all {
            let key = [c.n, c.t, c.r, "\(c.d)", "\(c.s)", "\(c.e)"].joined(separator: "\u{1}")
            if weeksOf[key] == nil {
                weeksOf[key] = []
                proto[key] = c
                order.append(key)
            }
            let w = M.parseWeeks(c.w)
            weeksOf[key]?.insert(w.isEmpty ? 0 : (w.min() ?? 0))
        }
        var out: [Course] = []
        for key in order {
            guard let p = proto[key], var set = weeksOf[key] else { continue }
            set.remove(0)
            let c = Course()
            c.n = p.n; c.t = p.t; c.r = p.r; c.d = p.d
            c.s = p.s; c.e = p.e
            c.timeMode = "period"
            c.w = M.compressWeeks(set)
            M.normalize(c)
            out.append(c)
        }
        out.sort { a, b in
            if a.d != b.d { return a.d < b.d }
            if a.s != b.s { return a.s < b.s }
            return a.n < b.n
        }
        return out
    }

    /// 单个单元格 → 可能包含多门课
    static func parseCell(_ text: String?, fallbackWeek: Int, day: Int,
                          startSection: Int, endSection: Int) -> [Course] {
        var out: [Course] = []
        let raw = (text ?? "").replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return out }
        let blocks = splitBlocks(raw)
        for var b in blocks {
            b = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if b.isEmpty { continue }
            var ls: [String] = []
            for s in b.components(separatedBy: "\n") {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { ls.append(t) }
            }
            if ls.count < 3 { continue }
            var codeIndex = -1
            for (i, v) in ls.enumerated() where regexMatch("^\\d+-(?:\\d{1,8})$", v) != nil {
                codeIndex = i
                break
            }
            if codeIndex < 1 { continue }
            let code = ls[codeIndex]
            let n = ls[0]
            var tb: [String] = []
            var i = 1
            while i < codeIndex { tb.append(ls[i]); i += 1 }
            let t = tb.isEmpty ? "—" : tb.joined(separator: ",")
            let room = (codeIndex + 1 < ls.count) ? ls[codeIndex + 1] : "—"

            var week = fallbackWeek
            if let m = regexMatch("^(\\d+)-(.+)$", code),
               let g = regexGroup(m, 1, code), let n2 = Int(g) { week = n2 }
            if week < 1 || week > M.TOTAL_WEEKS { continue }
            let cleanName = n.replacingOccurrences(of: "[理论]", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleanName.isEmpty { continue }
            let s = max(1, min(M.periods.count, startSection <= 0 ? 1 : startSection))
            let e = max(s, min(M.periods.count, endSection <= 0 ? s : endSection))

            let c = Course()
            c.n = cleanName
            let tt = t.trimmingCharacters(in: .whitespaces)
            let rr = room.trimmingCharacters(in: .whitespaces)
            c.t = tt.isEmpty ? "—" : tt
            c.r = rr.isEmpty ? "—" : rr
            c.d = day; c.s = s; c.e = e
            c.timeMode = "period"
            c.w = "\(week)"
            out.append(c)
        }
        return out
    }

    /// 按空行切分（容忍 "\\n\\s*\\n"）
    private static func splitBlocks(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let lines = s.components(separatedBy: "\n")
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(cur); cur = ""
            } else {
                cur += (cur.isEmpty ? "" : "\n") + l
            }
        }
        out.append(cur)
        return out
    }

    private static func bigSection(_ v: String) -> Int {
        let t = v.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n }
        let cn = ["一", "二", "三", "四", "五", "六"]
        for (i, c) in cn.enumerated() where c == t { return i + 1 }
        return 0
    }

    private static func cell(_ row: [String], _ i: Int) -> String {
        guard i >= 0, i < row.count else { return "" }
        return row[i]
    }

    /* ================= 二、工作台历导入 =================
       工作表名形如 2026.10；表头行 A 列含「姓名」且 B 列含「活动」；
       A:H 全空的行不导入；I 列是工作状态（可选）。
       ================================================= */

    struct WorkImport {
        var rows: [WorkRow] = []
        var months: [String] = []
    }

    static func parseWorkCalendar(_ book: Xlsx.Book) -> WorkImport {
        var out = WorkImport()
        var months: [String] = []
        let stamp = Int(Date().timeIntervalSince1970 * 1000)

        for (si, rows) in book.sheets.enumerated() {
            let sheetName = si < book.names.count ? book.names[si] : ""
            let nm = sheetName.trimmingCharacters(in: .whitespaces)
            guard let m = regexMatch("^(\\d{4})\\.(\\d{1,2})$", nm),
                  let gy = regexGroup(m, 1, nm), let gm = regexGroup(m, 2, nm),
                  let year = Int(gy), let month = Int(gm), (1...12).contains(month) else { continue }

            // 找表头行（A 列含「姓名」且 B 列含「活动」），数据紧随其后
            var firstData = 3   // 1 基；旧版约定
            for r in 0..<min(rows.count, 5) {
                let row = rows[r]
                if cell(row, 0).contains("姓名") && cell(row, 1).contains("活动") {
                    firstData = r + 2
                    break
                }
            }

            var r = firstData - 1
            while r < rows.count {
                let row = rows[r]
                r += 1
                if !rowHasContent(row) { continue }
                let w = WorkRow()
                w.id = "work-import-\(stamp)-\(out.rows.count)"
                w.date = String(format: "%04d-%02d-01", year, month)
                w.name = txt(cell(row, 0))
                w.activity = txt(cell(row, 1))
                w.content = txt(cell(row, 2))
                w.equipment = txt(cell(row, 3))
                w.returnTime = dateText(cell(row, 4))
                w.setupTime = dateText(cell(row, 5))
                w.completionTime = dateText(cell(row, 6))
                w.responsible = txt(cell(row, 7))
                w.remark = ""
                w.status = normalizeStatus(txt(cell(row, 8)), w.completionTime)
                out.rows.append(w)
                let key = String(format: "%04d-%02d", year, month)
                if !months.contains(key) { months.append(key) }
            }
        }
        out.months = months
        return out
    }

    /// 只检查 A:H，I 列（工作状态）不单独让空白行变成数据
    private static func rowHasContent(_ row: [String]) -> Bool {
        for i in 0..<8 where !txt(cell(row, i)).isEmpty { return true }
        return false
    }

    static func normalizeStatus(_ v: String, _ completionTime: String) -> String {
        let t = txt(v)
        if t == "已完成" || t == "未完成" { return t }
        return txt(completionTime).isEmpty ? "未完成" : "已完成"
    }

    private static func txt(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespaces)
    }

    /// 各种日期写法 → yyyy-MM-dd，认不出来就原样返回
    static func dateText(_ v: String) -> String {
        let raw = v.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "" }
        if let m = regexMatch("^(\\d{4})[/.\\-](\\d{1,2})[/.\\-](\\d{1,2})", raw),
           let y = regexGroup(m, 1, raw), let mo = regexGroup(m, 2, raw),
           let d = regexGroup(m, 3, raw), let mi = Int(mo), let di = Int(d) {
            return String(format: "%@-%02d-%02d", y, mi, di)
        }
        if let m = regexMatch("^(\\d{4})(\\d{2})(\\d{2})$", raw),
           let y = regexGroup(m, 1, raw), let mo = regexGroup(m, 2, raw),
           let d = regexGroup(m, 3, raw) {
            return y + "-" + mo + "-" + d
        }
        return raw
    }
}
