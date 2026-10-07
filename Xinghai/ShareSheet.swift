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

/* ================= CSV 导出（带 BOM，Excel 可直接打开） ================= */

enum Exporter {

    private static func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func line(_ fs: [String]) -> String {
        fs.map(field).joined(separator: ",")
    }

    private static func dateOnly(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > 10 ? String(t.prefix(10)) : t
    }

    static func writeCsv(_ fileName: String, _ lines: [String]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n")
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 成员课表 CSV
    static func timetableCsv(_ person: Person) -> (String, [String]) {
        var lines: [String] = []
        let title = "2026-2027学年第一学期 宣传部课表 " + person.name
            + (person.cls.isEmpty ? "" : "（\(person.cls)）")
        lines.append(title)
        lines.append(line(["星期", "节次", "时间", "课程名称", "教师", "教室", "周次"]))
        let sorted = person.courses.sorted { a, b in
            if a.d != b.d { return a.d < b.d }
            if a.s != b.s { return a.s < b.s }
            return a.n < b.n
        }
        for c in sorted {
            lines.append(line([
                M.days[c.d - 1], M.periodLabel(c.s, c.e), M.courseRange(c),
                c.n, c.t, c.r, c.w.isEmpty ? "" : c.w + " 周"
            ]))
        }
        return ("音教宣传部课表_" + person.name + ".csv", lines)
    }

    /// 工作台历 CSV（表头与网页版 / 安卓版完全一致）
    static func worksCsv(_ year: Int, _ month: Int, works: [WorkRow]) -> (String, [String]) {
        var lines: [String] = []
        lines.append("2026-2027学年第一学期 宣传部工作台历 \(year).\(month)")
        lines.append(line(["姓名", "活动名称", "工作内容", "摄影设备名称",
                           "归还时间", "布置时间", "完成时间", "负责人", "工作进度"]))
        var valid = M.worksOfMonth(year, month, works: works).filter { $0.hasContent }
        valid.sort { a, b in
            let x = M.workDate(a), y = M.workDate(b)
            if x != y { return x < y }
            return a.name < b.name
        }
        for r in valid {
            lines.append(line([
                r.name, r.activity, r.content, r.equipment,
                dateOnly(r.returnTime), dateOnly(r.setupTime), dateOnly(r.completionTime),
                r.responsible, r.done ? "已完成" : "未完成"
            ]))
        }
        return (String(format: "音教宣传部工作台历_%d_%d月.csv", year, month), lines)
    }
}
