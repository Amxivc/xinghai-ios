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
    /// 批量选择时的临时勾选标记（不落盘，与安卓端 selected 一致）
    var selected = false

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

    static func isoToDate(_ s: String) -> Date {
        guard let (y, m, d) = parseYmd(s) else { return Date() }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    static func dateToIso(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    static func hmToDate(_ s: String) -> Date {
        let a = s.components(separatedBy: ":")
        var c = DateComponents()
        c.hour = Int(a.first ?? "") ?? 9
        c.minute = a.count > 1 ? (Int(a[1]) ?? 0) : 0
        return Calendar.current.date(from: c) ?? Date()
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

    /// 自定义时间折算节次（编辑器保存时使用）
    static func sectionFor(_ v: String, _ isEnd: Bool) -> Int {
        sectionForClock(v, isEnd)
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

    /* ================= 同一节课被存成多条记录 → 合并 =================
       导入课表或反复编辑后，同一节课常常留下多条记录：同一天、同课程名、同教室、
       同教师，只是「周次」或「节次」范围写得不一样。这些记录各算一门的话，课表会把
       它并排画成左右两块（看起来就是「一节课变成两节」），导出也会多出重复行。

       判定为同一节课（三条同时满足）：
         ① 星期 / 课程名 / 教室 / 教师 一致（去空格、统一全半角括号）
         ② 周次集合相交 —— 存在某一周两条都会出现
         ③ 节次区间相交 —— 排除「5-6 节 + 7-8 节」这种连排的另外一节课
       合并结果：节次取并集、周次取并集，保留起点更早的那条。

       ⚠ 判周次这一步不能省：「周2-6」+「周8-18」是同一门课的前后两段（第 7 周军训
         空档），合并成「2-18」会把第 7 周也算成有课。规则与网页版、安卓版一致。 */

    private static func normKey(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    private static func sameCourseKey(_ c: Course) -> String {
        "\(c.d)\u{1}\(normKey(c.n))\u{1}\(normKey(c.r))\u{1}\(normKey(c.t))"
    }

    /// 课程某端的时刻：自定义时间优先，其次取该节次的起/止时刻
    static func courseClock(_ c: Course, start: Bool) -> String {
        if c.timeMode == "custom" {
            let v = start ? c.customStart : c.customEnd
            if !v.isEmpty { return v }
        }
        let i = start ? c.s : c.e
        guard (1...periods.count).contains(i) else { return "" }
        let se = periods[i - 1][1].components(separatedBy: "-")
        if start { return se.first ?? "" }
        return se.count > 1 ? se[1] : ""
    }

    static func mergeSameCourses(_ p: Person) {
        guard p.courses.count > 1 else { return }
        var bucket: [String: [Int]] = [:]
        for (i, c) in p.courses.enumerated() {
            bucket[sameCourseKey(c), default: []].append(i)
        }
        var dead = Set<Int>()
        for (_, idx) in bucket where idx.count > 1 {
            var again = true
            while again {
                again = false
                outer: for x in 0..<idx.count {
                    if dead.contains(idx[x]) { continue }
                    for y in (x + 1)..<idx.count {
                        if dead.contains(idx[y]) { continue }
                        let a = p.courses[idx[x]], b = p.courses[idx[y]]
                        if a.ws.isDisjoint(with: b.ws) { continue }   // 周次不相交 → 前后两段
                        if a.e < b.s || b.e < a.s { continue }        // 节次不相交 → 连排的另一节
                        let base  = (a.s, -a.e) <= (b.s, -b.e) ? a : b
                        let other = base === a ? b : a
                        if base.timeMode == "custom" {
                            // 自定义时间以起止时刻为准：把并集写回自定义时间，
                            // 否则 normalize 会按旧时刻把 s/e 又缩回去。
                            let os = courseClock(other, start: true)
                            let oe = courseClock(other, start: false)
                            let bs = courseClock(base, start: true)
                            let be = courseClock(base, start: false)
                            let om1 = clockMinutes(os), om2 = clockMinutes(oe)
                            if om1 >= 0, om1 < clockMinutes(bs) { base.customStart = os }
                            if om2 >= 0, om2 > clockMinutes(be) { base.customEnd = oe }
                        }
                        base.s = min(a.s, b.s)
                        base.e = max(a.e, b.e)
                        base.ws.formUnion(other.ws)
                        base.w = compressWeeks(base.ws)
                        normalize(base)
                        // ⚠ 被删的必须是 base 之外的那条，不能图省事写死 idx[y]：
                        // 起点更早的那条可能是 b（如「10-11 周5-18」在前、「9-10 周8-18」在后），
                        // 这时 base=b、other=a，写死 y 会把刚并好的记录删掉，并集白算。
                        let deadIdx = base === a ? idx[y] : idx[x]
                        dead.insert(deadIdx)
                        again = true
                        break outer
                    }
                }
            }
        }
        if !dead.isEmpty {
            p.courses = p.courses.enumerated()
                .filter { !dead.contains($0.offset) }
                .map { $0.element }
        }
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

    /// 按成员列表的当前顺序切出班级分组名（未排序前请先 sortPersons）
    static func classGroups(_ persons: [Person]) -> [String] {
        var out: [String] = []
        for p in persons where out.last != p.cls { out.append(p.cls) }
        return out
    }

    /// 每个班级在 persons 里的起止下标 [start, end)，与 classGroups 一一对应
    static func classRanges(_ persons: [Person]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i < persons.count {
            var j = i
            while j < persons.count && persons[j].cls == persons[i].cls { j += 1 }
            out.append((i, j))
            i = j
        }
        return out
    }

    /* ================= 时间换算（时间查找） ================= */

    /// yyyy-MM-dd → (第几周, 周几)；不在本学期第 1—21 周内返回 nil
    static func semesterOf(_ iso: String?) -> (week: Int, day: Int)? {
        guard let ymd = parseYmd(iso) else { return nil }
        let cal = Calendar.current
        guard let date = cal.date(from: DateComponents(year: ymd.0, month: ymd.1, day: ymd.2)) else {
            return nil
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start),
                                      to: cal.startOfDay(for: date)).day ?? -1
        if days < 0 || days >= TOTAL_WEEKS * 7 { return nil }
        return (days / 7 + 1, days % 7 + 1)
    }

    /// 分钟数 → "1小时20分钟"
    static func durationText(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)分钟" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "\(h)小时\(m)分钟" : "\(h)小时"
    }

    /// 课程在某天的起止分钟（自定义时间优先）
    static func courseMinutes(_ c: Course) -> (Int, Int) {
        if c.timeMode == "custom" && !c.customStart.isEmpty && !c.customEnd.isEmpty {
            return (clockMinutes(c.customStart), clockMinutes(c.customEnd))
        }
        if c.s < 1 || c.s > periods.count || c.e < 1 || c.e > periods.count { return (-1, -1) }
        let a = clockMinutes(periods[c.s - 1][1].components(separatedBy: "-")[0])
        let b = clockMinutes(periods[c.e - 1][1].components(separatedBy: "-")[1])
        return (a, b)
    }

    static func hhmm(_ mins: Int) -> String { pad2(mins / 60) + ":" + pad2(mins % 60) }

    /// Date → "HH:mm"
    static func hmString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /* ================= 导出工具 ================= */

    /// 可导出的记录数（只算「有内容」的）
    static func exportableCount(_ year: Int, _ month: Int, works: [WorkRow]) -> Int {
        worksOfMonth(year, month, works: works).filter { $0.hasContent }.count
    }

    /// 出现过的年份（降序），至少包含当前年份前后 5 年
    static func workYears(_ curYear: Int, works: [WorkRow]) -> [Int] {
        var set = Set<Int>()
        for y in (curYear - 5)...(curYear + 5) { set.insert(y) }
        for r in works where regexMatch("^\\d{4}-\\d{2}-\\d{2}$", r.date) != nil {
            if let y = Int(r.date.prefix(4)) { set.insert(y) }
        }
        return set.sorted(by: >)
    }

    /// 各种日期写法 → yyyy-MM-dd（认不出就原样返回），空值返回 ""
    static func dateOnly(_ s: String?) -> String {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
        let t = raw.count > 10 ? String(raw.prefix(10)) : raw
        guard let ymd = parseYmd(t) else { return t }
        return String(format: "%04d-%02d-%02d", ymd.0, ymd.1, ymd.2)
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
            // 同一节课被存成多条记录时合并成一条（否则课表会把它并排画成两节）。
            // 必须在 normalize 之后：合并要靠周次集合判断「是不是同一周的同一节课」。
            mergeSameCourses(p)
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
