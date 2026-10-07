import Foundation

func notBlank(_ s: String?) -> Bool {
    guard let s = s else { return false }
    return !s.trimmingCharacters(in: .whitespaces).isEmpty
}

func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

func regexMatch(_ pattern: String, _ s: String) -> NSTextCheckingResult? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
}

func regexGroup(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
    guard let r = Range(m.range(at: i), in: s) else { return nil }
    return String(s[r])
}

final class Course {
    var n = ""          // 课程名
    var t = ""          // 教师
    var r = ""          // 教室
    var d = 1           // 星期 1-7
    var p = 1           // 旧版大节
    var s = 1, e = 1    // 小节起止
    var w = ""          // 周次，如 "2-18" / "3,5,7"
    var timeMode = "period"
    var customStart = ""
    var customEnd = ""
    var ws: Set<Int> = []

    func inWeek(_ week: Int) -> Bool { ws.contains(week) }
    var span: Int { e - s + 1 }
}

final class Person {
    var name = ""
    var cls = ""
    var courses: [Course] = []
}

final class WorkRow {
    var id = ""
    var date = ""
    var name = ""
    var activity = ""
    var content = ""
    var equipment = ""
    var returnTime = ""
    var setupTime = ""
    var completionTime = ""
    var remark = ""
    var responsible = ""
    var status = ""

    var hasContent: Bool {
        notBlank(name) || notBlank(activity) || notBlank(content) || notBlank(equipment)
            || notBlank(returnTime) || notBlank(setupTime) || notBlank(completionTime)
            || notBlank(responsible)
    }

    var done: Bool {
        let s = status.trimmingCharacters(in: .whitespaces)
        if s == "已完成" { return true }
        if s == "未完成" { return false }
        return notBlank(completionTime)
    }

    var statusText: String {
        if !hasContent { return "" }
        return done ? "已完成" : "未完成"
    }
}

enum M {

    /* ================= 常量 ================= */

    /// 节次与上课时间（星海教〔2026〕69 号）
    static let periods: [[String]] = [
        ["第一节",   "09:00-09:40"],
        ["第二节",   "09:45-10:25"],
        ["第三节",   "10:40-11:20"],
        ["第四节",   "11:25-12:05"],
        ["第五节",   "13:30-14:10"],
        ["第六节",   "14:15-14:55"],
        ["第七节",   "15:10-15:50"],
        ["第八节",   "15:55-16:35"],
        ["第九节",   "16:40-17:20"],
        ["第十节",   "18:20-19:00"],
        ["第十一节", "19:05-19:45"],
        ["第十二节", "20:00-20:40"],
        ["第十三节", "20:45-21:25"]
    ]

    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let TOTAL_WEEKS = 21

    /// 某年某月的天数（解包失败兜底 30）
    static func daysInMonth(year: Int, month: Int) -> Int {
        var c = DateComponents(year: year, month: month)
        guard let date = Calendar.current.date(from: c),
              let range = Calendar.current.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    /// 学期首日：2026-08-24
    static let startComponents = DateComponents(year: 2026, month: 8, day: 24)

    /// 旧版大节 → 小节范围
    static let legacy = [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], [12, 13]]

    static let cnNums = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
                         "十一", "十二", "十三"]

    static var start: Date {
        Calendar.current.date(from: startComponents) ?? Date()
    }

    /* ================= 周次 / 日期换算 ================= */

    private static func daysFromStart() -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: start),
                                  to: cal.startOfDay(for: Date())).day ?? 0
    }

    /// 当前教学周（1..21）
    static var currentWeek: Int {
        var w = daysFromStart() / 7 + 1
        if w < 1 { w = 1 }
        if w > TOTAL_WEEKS { w = TOTAL_WEEKS }
        return w
    }

    /// 今天是周几（1..7），学期外返回 0
    static var todayDay: Int {
        let d = daysFromStart()
        if d < 0 || d >= TOTAL_WEEKS * 7 { return 0 }
        return d % 7 + 1
    }

    static func dateOfWeekDay(_ week: Int, _ day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: (week - 1) * 7 + (day - 1), to: start) ?? start
    }

    /// 第 week 周、周 day 的日期 MM-DD
    static func weekDate(_ week: Int, _ day: Int) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: dateOfWeekDay(week, day))
        return pad2(c.month ?? 1) + "-" + pad2(c.day ?? 1)
    }

    /// 第 week 周、周 day 的日期 yyyy-MM-dd
    static func isoOfWeekDay(_ week: Int, _ day: Int) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dateOfWeekDay(week, day))
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    static func todayIso() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    /// 解析 yyyy-MM-dd（也接受 yyyy/MM/dd、yyyy.MM.dd）
    static func parseYmd(_ s: String?) -> (Int, Int, Int)? {
        guard let s = s?.trimmingCharacters(in: .whitespaces),
              let m = regexMatch("^(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})", s),
              let y = regexGroup(m, 1, s).flatMap({ Int($0) }),
              let mo = regexGroup(m, 2, s).flatMap({ Int($0) }),
              let d = regexGroup(m, 3, s).flatMap({ Int($0) }),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        return (y, mo, d)
    }

    static func formatCn(_ iso: String?) -> String {
        guard let (y, m, d) = parseYmd(iso) else { return iso ?? "" }
        return "\(y)年\(m)月\(d)日"
    }

    /* ================= 周次字符串 ================= */

    /// 解析周次字符串："2-18,20" → {2..18, 20}
    static func parseWeeks(_ w: String?) -> Set<Int> {
        var set = Set<Int>()
        guard let w = w else { return set }
        for part0 in w.components(separatedBy: ",") {
            let part = part0.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if let dash = part.firstIndex(of: "-") {
                let aStr = part[part.startIndex..<dash].trimmingCharacters(in: .whitespaces)
                let bStr = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                if let a = Int(aStr), let b = Int(bStr), a >= 1, b >= a {
                    for i in a...b { set.insert(i) }
                }
            } else if let n = Int(part) {
                set.insert(n)
            }
        }
        return set
    }

    /// {2,3,4,7} → "2-4,7"
    static func compressWeeks(_ set: Set<Int>?) -> String {
        var nums = (set ?? []).filter { $0 >= 1 && $0 <= TOTAL_WEEKS }.sorted()
        var out = ""
        var i = 0
        while i < nums.count {
            var a = nums[i], b = a
            while i + 1 < nums.count && nums[i + 1] == b + 1 { i += 1; b = nums[i] }
            if !out.isEmpty { out += "," }
            out += a == b ? "\(a)" : "\(a)-\(b)"
            i += 1
        }
        return out
    }

    /* ================= 时间与节次 ================= */

    static func normalizeClock(_ v: String?) -> String {
        guard var v = v else { return "" }
        v = v.trimmingCharacters(in: .whitespaces)
        if regexMatch("^\\d{1,2}:\\d{2}$", v) != nil {
            let a = v.components(separatedBy: ":")
            if let h = Int(a[0]), let mi = Int(a[1]), h <= 23, mi <= 59 {
                return pad2(h) + ":" + pad2(mi)
            }
            return ""
        }
        if regexMatch("^\\d{3,4}$", v) != nil, let n = Int(v) {
            return pad2(n / 100) + ":" + pad2(n % 100)
        }
        return ""
    }

    static func clockMinutes(_ v: String?) -> Int {
        let s = normalizeClock(v)
        if s.isEmpty { return -1 }
        let a = s.components(separatedBy: ":")
        return (Int(a[0]) ?? 0) * 60 + (Int(a[1]) ?? 0)
    }

    private static func sectionForClock(_ v: String, _ isEnd: Bool) -> Int {
        let mins = clockMinutes(v)
        if mins < 0 { return 1 }
        if isEnd {
            for i in stride(from: periods.count, through: 1, by: -1) {
                let start = clockMinutes(periods[i - 1][1].components(separatedBy: "-")[0]) ?? 0
                if mins >= start { return i }
            }
            return 1
        }
        for i in 1...periods.count {
            let se = periods[i - 1][1].components(separatedBy: "-")
            let end = clockMinutes(se[1]) ?? 0
            if mins < end { return i }
        }
        return periods.count
    }

    /// 补全课程的规范化字段（s/e/周次集合）
    static func normalize(_ c: Course) {
        if c.timeMode == "custom" && !c.customStart.isEmpty && !c.customEnd.isEmpty {
            c.customStart = normalizeClock(c.customStart)
            c.customEnd = normalizeClock(c.customEnd)
            let a = clockMinutes(c.customStart), b = clockMinutes(c.customEnd)
            if a >= 0 && b >= 0 && b > a {
                c.s = sectionForClock(c.customStart, false)
                c.e = sectionForClock(c.customEnd, true)
                if c.e < c.s { c.e = c.s }
            }
        }
        if c.s <= 0 || c.e <= 0 {
            let idx = c.p - 1
            if idx >= 0 && idx < legacy.count {
                c.s = legacy[idx][0]
                c.e = legacy[idx][1]
            } else {
                c.s = 1; c.e = 1
            }
        }
        c.s = max(1, min(periods.count, c.s))
        c.e = max(c.s, min(periods.count, c.e))
        if c.timeMode != "custom" { c.timeMode = "period" }
        c.ws = parseWeeks(c.w)
    }

    /// 小节范围对应的真实时间，如 09:00-10:25
    static func timeRange(_ s: Int, _ e: Int) -> String {
        guard (1...periods.count).contains(s), (1...periods.count).contains(e) else { return "" }
        let a = periods[s - 1][1].components(separatedBy: "-")[0]
        let b = periods[e - 1][1].components(separatedBy: "-")[1]
        return a + "-" + b
    }

    static func periodLabel(_ s: Int, _ e: Int) -> String {
        s == e ? "第\(cn(s))节" : "第\(cn(s))-\(cn(e))节"
    }

    static func cn(_ n: Int) -> String {
        (1...cnNums.count).contains(n) ? cnNums[n - 1] : "\(n)"
    }

    /// 课程对应的显示时间（自定义优先）
    static func courseRange(_ c: Course) -> String {
        if c.timeMode == "custom" && !c.customStart.isEmpty && !c.customEnd.isEmpty {
            return c.customStart + "-" + c.customEnd
        }
        return timeRange(c.s, c.e)
    }

    /* ================= 班级分组 ================= */

    static func classKey(_ cls: String?) -> Int {
        guard let cls = cls,
              let m = regexMatch("(\\d{4})\\s*级\\s*(\\d+)\\s*班", cls),
              let y = regexGroup(m, 1, cls).flatMap({ Int($0) }),
              let n = regexGroup(m, 2, cls).flatMap({ Int($0) }) else { return 999_999 }
        return y * 100 + n
    }

    static func sortPersons(_ persons: inout [Person]) {
        persons.sort { a, b in
            let ka = classKey(a.cls), kb = classKey(b.cls)
            if ka != kb { return ka < kb }
            return a.name < b.name
        }
    }

    /* ================= 台历 ================= */

    /// 工作在日历上的归位日期：优先「布置」日期，其次 date 字段
    static func workDate(_ r: WorkRow) -> String {
        let t = r.setupTime.trimmingCharacters(in: .whitespaces)
        if t.count >= 10, regexMatch("^\\d{4}-\\d{2}-\\d{2}", t) != nil {
            return String(t.prefix(10))
        }
        return r.date
    }

    static func worksOfMonth(_ year: Int, _ month: Int, works: [WorkRow]) -> [WorkRow] {
        let prefix = String(format: "%04d-%02d-", year, month)
        return works.filter { workDate($0).hasPrefix(prefix) }
    }

    /// 某年某月统计：(记录条数, 已完成, 未完成)。口径与网页版一致：
    /// 条数＝该月全部记录；完成情况只统计填了姓名的记录。
    static func workStats(_ year: Int, _ month: Int, works: [WorkRow]) -> (Int, Int, Int) {
        var total = 0, done = 0, pending = 0
        for r in worksOfMonth(year, month, works: works) {
            total += 1
            if !notBlank(r.name) { continue }
            let s = r.status.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty {
                if s == "已完成" { done += 1 }
                else if s == "未完成" { pending += 1 }
            } else if notBlank(r.completionTime) {
                done += 1
            } else {
                pending += 1
            }
        }
        return (total, done, pending)
    }

    /* ================= JSON ================= */

    static func toJson(persons: [Person], works: [WorkRow]) -> [String: Any] {
        var tt: [[String: Any]] = []
        for p in persons {
            var cs: [[String: Any]] = []
            for c in p.courses {
                cs.append(["n": c.n, "t": c.t, "r": c.r, "d": c.d, "p": c.p, "w": c.w,
                           "s": c.s, "e": c.e, "timeMode": c.timeMode,
                           "customStart": c.customStart, "customEnd": c.customEnd])
            }
            tt.append(["name": p.name, "cls": p.cls, "courses": cs])
        }
        var ws: [[String: Any]] = []
        for r in works {
            var j: [String: Any] = [
                "id": r.id, "date": r.date, "name": r.name, "activity": r.activity,
                "content": r.content, "equipment": r.equipment, "returnTime": r.returnTime,
                "setupTime": r.setupTime, "completionTime": r.completionTime,
                "remark": r.remark, "responsible": r.responsible]
            if !r.status.isEmpty { j["status"] = r.status }
            ws.append(j)
        }
        return ["timetable": tt, "workCalendar": ws]
    }

    static func fromJson(_ root: [String: Any]) -> ([Person], [WorkRow])? {
        guard let tt = root["timetable"] as? [[String: Any]] else { return nil }
        var people: [Person] = []
        for o in tt {
            let p = Person()
            p.name = o["name"] as? String ?? ""
            p.cls = o["cls"] as? String ?? ""
            if let cs = o["courses"] as? [[String: Any]] {
                for j in cs {
                    let c = Course()
                    c.n = j["n"] as? String ?? ""
                    c.t = j["t"] as? String ?? ""
                    c.r = j["r"] as? String ?? ""
                    c.d = j["d"] as? Int ?? 1
                    c.p = j["p"] as? Int ?? 1
                    c.w = j["w"] as? String ?? ""
                    c.s = j["s"] as? Int ?? 0
                    c.e = j["e"] as? Int ?? 0
                    c.timeMode = j["timeMode"] as? String ?? "period"
                    c.customStart = j["customStart"] as? String ?? ""
                    c.customEnd = j["customEnd"] as? String ?? ""
                    normalize(c)
                    p.courses.append(c)
                }
            }
            people.append(p)
        }
        guard !people.isEmpty else { return nil }
        sortPersons(&people)

        var works: [WorkRow] = []
        if let wa = root["workCalendar"] as? [[String: Any]] {
            for (i, j) in wa.enumerated() {
                let r = WorkRow()
                r.id = j["id"] as? String ?? "work-\(i)"
                r.date = j["date"] as? String ?? ""
                r.name = j["name"] as? String ?? ""
                r.activity = j["activity"] as? String ?? ""
                r.content = j["content"] as? String ?? ""
                r.equipment = j["equipment"] as? String ?? ""
                r.returnTime = j["returnTime"] as? String ?? ""
                r.setupTime = j["setupTime"] as? String ?? ""
                r.completionTime = j["completionTime"] as? String ?? ""
                r.remark = j["remark"] as? String ?? ""
                r.responsible = j["responsible"] as? String ?? ""
                r.status = j["status"] as? String ?? ""
                works.append(r)
            }
        }
        return (people, works)
    }
}
