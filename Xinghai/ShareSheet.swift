import SwiftUI
import UIKit

/* ================= 系统分享 ================= */

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/* ================= xlsx 导出 =================
   表头、工作表命名、文件命名与安卓端 WorkExport.java / 网页版逐字一致。
   ============================================ */

enum Exporter {

    /* ---------- 落盘 ---------- */

    static func write(_ fileName: String, _ sheets: [Xlsx.Sheet]) -> URL? {
        guard !sheets.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try Xlsx.write(sheets).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /* ---------- 课表 ---------- */

    static let timetableHeader = ["星期", "节次", "时间", "课程名称", "教师", "教室", "周次"]

    static func timetableSheets(_ persons: [Person]) -> [Xlsx.Sheet] {
        var out: [Xlsx.Sheet] = []
        for p in persons {
            var s = Xlsx.Sheet()
            s.name = p.name.isEmpty ? "课表" : p.name
            s.title = "2026-2027学年第一学期 宣传部课表 " + p.name
                + (p.cls.isEmpty ? "" : "（\(p.cls)）")
            s.header = timetableHeader
            let sorted = p.courses.sorted { a, b in
                if a.d != b.d { return a.d < b.d }
                if a.s != b.s { return a.s < b.s }
                return a.n < b.n
            }
            for c in sorted {
                s.rows.append([
                    M.days[max(0, min(6, c.d - 1))], M.periodLabel(c.s, c.e), M.courseRange(c),
                    c.n, c.t, c.r, c.w.isEmpty ? "" : c.w + " 周"
                ])
            }
            out.append(s)
        }
        return out
    }

    static func timetableFileName(_ persons: [Person]) -> String {
        if persons.count == 1 {
            let n = persons[0].name.isEmpty ? "成员" : persons[0].name
            return "音教宣传部课表_\(n).xlsx"
        }
        return "音教宣传部课表_\(persons.count)人.xlsx"
    }

    /* ---------- 工作台历（按月份多工作表） ---------- */

    static let workHeader = ["姓名", "活动名称", "工作内容", "摄影设备名称",
                             "归还时间", "布置时间", "完成时间", "负责人", "工作进度"]

    static func workSheets(_ year: Int, _ months: [Int], works: [WorkRow]) -> [Xlsx.Sheet] {
        var out: [Xlsx.Sheet] = []
        for month in months.sorted() {
            var valid = M.worksOfMonth(year, month, works: works).filter { $0.hasContent }
            if valid.isEmpty { continue }
            valid.sort { a, b in
                let x = M.workDate(a), y = M.workDate(b)
                if x != y { return x < y }
                return a.name < b.name
            }
            var s = Xlsx.Sheet()
            s.name = "\(year).\(month)"
            s.title = "2026-2027学年第一学期 宣传部工作台历 \(year).\(month)"
            s.header = workHeader
            for r in valid {
                s.rows.append([
                    r.name, r.activity, r.content, r.equipment,
                    M.dateOnly(r.returnTime), M.dateOnly(r.setupTime), M.dateOnly(r.completionTime),
                    r.responsible, r.done ? "已完成" : "未完成"
                ])
            }
            out.append(s)
        }
        return out
    }

    static func workFileName(_ year: Int, _ months: [Int]) -> String {
        let rangeName: String
        if months.count == 1 { rangeName = "\(months[0])月" }
        else if months.count == 12 { rangeName = "全年" }
        else { rangeName = "多个月" }
        return "音教宣传部工作台历_\(year)_\(rangeName).xlsx"
    }
}
