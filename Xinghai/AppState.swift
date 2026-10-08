import Foundation
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var persons: [Person] = []
    @Published var works: [WorkRow] = []
    @Published var dataSource = "local"   // "cb" / "sb" / "cache" / "local"
    @Published var dataUpdatedAt = ""
    @Published var loading = false
    @Published var banner: String? = nil

    @Published var cbUser: String? = nil
    @Published var cbAdmin = false
    @Published var sbUser: String? = nil
    @Published var sbAdmin = false

    @Published var saving = false
    @Published var toast: String? = nil
    private var toastWork: DispatchWorkItem? = nil

    /* ---- 双服务器一致性状态（读写不同源会导致「改了又变回去」，必须盯着） ---- */
    /// 两台服务器各自那份数据的写入时间
    @Published var cbAt: Date? = nil
    @Published var sbAt: Date? = nil
    /// 两台各自是否取到了数据
    @Published var cbGot = false
    @Published var sbGot = false
    /// 需要提醒用户的一致性提示（空串 = 没问题）
    @Published var cloudNote = ""

    private let d = UserDefaults.standard

    /// 「保持登录状态（下次打开免登录）」——不勾时凭证只活在本次会话内存里
    @Published var remember = true
    private var memTok: [String: String] = [:]

    private func tok(_ key: String) -> String {
        if let v = memTok[key] { return v }
        if remember, let v = d.string(forKey: key) { return v }
        return ""
    }

    private func setTok(_ key: String, _ v: String) {
        memTok[key] = v
        if remember { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
    }

    private func setMeta(_ key: String, _ v: Any?) {
        if remember, let v = v { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
    }

    var cbToken: String {
        get { tok("cb_token") }
        set { setTok("cb_token", newValue) }
    }
    var cbRefresh: String {
        get { tok("cb_refresh") }
        set { setTok("cb_refresh", newValue) }
    }
    var sbToken: String {
        get { tok("sb_token") }
        set { setTok("sb_token", newValue) }
    }
    var sbRefresh: String {
        get { tok("sb_refresh") }
        set { setTok("sb_refresh", newValue) }
    }

    var isLoggedIn: Bool { cbUser != nil || sbUser != nil }
    var isAdmin: Bool { cbAdmin || sbAdmin }
    var isCbLogged: Bool { !cbToken.isEmpty }
    var isSbLogged: Bool { !sbToken.isEmpty }
    var loginLabel: String {
        if cbUser != nil && sbUser != nil { return "腾讯云 + Supabase" }
        if cbUser != nil { return "腾讯云" }
        if sbUser != nil { return "Supabase" }
        return ""
    }

    /// 毫秒/时间戳 → "MM-dd HH:mm"
    func clockText(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    var totalCourses: Int {
        persons.reduce(0) { $0 + $1.courses.count }
    }

    /// 数据来源：按两台的实际读取结果算，而不是「首选后端」。
    /// v0.4.2 起读取是「两台都读、取最新的那份」，主 / 备之分已经不存在：
    /// 旧写法在只登录一台时会显示「Supabase」，而数据其实来自腾讯云，纯属误导。
    var sourceLabel: String {
        if cbGot && sbGot {
            if Cloud.sameVersion(cbAt, sbAt) {
                return "腾讯云 + Supabase（已一致）"
            }
            return (cbAt ?? .distantPast) > (sbAt ?? .distantPast)
                ? "腾讯云（较新）" : "Supabase（较新）"
        }
        if cbGot { return "腾讯云（只连上一台）" }
        if sbGot { return "Supabase（只连上一台）" }
        if !persons.isEmpty { return "本地缓存" }
        return "内置数据"
    }

    /// 只登录一台时的风险提示。三种情况说法必须不同，否则会出现「两台已一致」
    /// 却写「另一台是旧数据」这种自相矛盾：
    ///   ① 未登录那台反而更新 → 危险是「你的改动会被它覆盖」（方向相反）
    ///   ② 两台时间戳相同     → 数据没差，只是改动写不进未登录那台
    ///   ③ 未登录那台确实旧   → 改动写不进它，它会一直是旧数据
    var halfLoginWarning: String? {
        let hasCb = !cbToken.isEmpty, hasSb = !sbToken.isEmpty
        guard hasCb != hasSb else { return nil }
        let selfName = hasCb ? "腾讯云" : "Supabase"
        let otherName = hasCb ? "Supabase" : "腾讯云"
        let body: String
        if cbGot && sbGot, Cloud.sameVersion(cbAt, sbAt) {
            body = "两台数据已一致，但你的改动只会写进" + selfName
        } else {
            let otherNewer = hasCb
                ? (sbGot && (sbAt ?? .distantPast) > (cbAt ?? .distantPast))
                : (cbGot && (cbAt ?? .distantPast) > (sbAt ?? .distantPast))
            body = otherNewer
                ? otherName + "上有更新的数据，你的改动会被它覆盖"
                : "另一台（" + otherName + "）会一直是旧数据"
        }
        return "⚠ 只连上一台服务器：" + body + "，建议用「双端同时」重登"
    }

    private init() {
        remember = d.object(forKey: "remember_login") as? Bool ?? true
        if remember {
            if let u = d.string(forKey: "cb_user") {
                cbUser = u
                cbAdmin = d.bool(forKey: "cb_admin")
            }
            if let u = d.string(forKey: "sb_user") {
                sbUser = u
                sbAdmin = d.bool(forKey: "sb_admin")
            }
        }
        loadCache()
        // 启动后台静默刷新：缓存先上屏，云端数据回来后自动替换
        load()
    }

    /* ================= 轻提示 ================= */

    func showToast(_ s: String) {
        toastWork?.cancel()
        withAnimation { toast = s }
        let w = DispatchWorkItem { [weak self] in
            withAnimation { if self?.toast == s { self?.toast = nil } }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }

    /// Course / WorkRow 是 class，原地修改不会触发刷新；改完调这个
    func poke() {
        persons = persons
        works = works
    }

    /* ================= 保存到云端 ================= */

    /// 乐观更新：调用方先改内存数据，失败时由 revert 回滚现场。
    ///
    /// 旧写法是「两台里写成一台就 ok」，本地缓存也照存。于是在只登录一台、或某台报错时，
    /// 界面提示成功、本地也留下了改动，但另一台仍是旧数据，下次进来就被覆盖回去。
    /// 现在：① 两台共用同一个时间戳（也是读取端挑数据的依据）；② 一台都没写成 = 失败，
    /// 且不落本地缓存；③ 写成了但不齐，提示里如实说清缺了哪台、为什么。
    func saveData(_ okMsg: String, revert: (() -> Void)? = nil) {
        guard !saving else {
            revert?()
            showToast("正在保存，请稍候")
            return
        }
        saving = true
        let personsSnapshot = persons
        let worksSnapshot = works
        let cbTok = cbToken
        let sbTok = sbToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let payload = M.toJson(persons: personsSnapshot, works: worksSnapshot)
            let iso = Cloud.nowIsoText()

            var cbOk = false, sbOk = false
            var cbMsg = "腾讯云未登录", sbMsg = "Supabase 未登录"
            if !cbTok.isEmpty {
                do { try Cloud.cbWrite(payload, token: cbTok, iso: iso); cbOk = true }
                catch { cbMsg = AppState.translate(error) }
            }
            if !sbTok.isEmpty {
                do { try Cloud.sbWrite(payload, token: sbTok, iso: iso); sbOk = true }
                catch { sbMsg = AppState.translate(error) }
            }

            let ok = cbOk || sbOk
            let at = Cloud.parseIso(iso)

            var msg = ""
            if cbOk && sbOk {
                msg = "已保存到腾讯云 + Supabase"
            } else if ok {
                let missing = cbOk ? "Supabase" : "腾讯云"
                let why = cbOk ? sbMsg : cbMsg
                let missingLogged = cbOk ? !sbTok.isEmpty : !cbTok.isEmpty
                msg = "已保存到" + (cbOk ? "腾讯云" : "Supabase")
                    + (missingLogged ? "，\(missing)写入失败：\(why)"
                                     : "，\(missing)未登录，该端仍是旧数据")
            } else if cbTok.isEmpty && sbTok.isEmpty {
                msg = "请先登录再保存"
            } else {
                msg = "保存失败：" + (cbTok.isEmpty ? sbMsg : cbMsg)
            }

            DispatchQueue.main.async {
                self.saving = false
                if ok {
                    self.saveCache(payload)
                    if cbOk { self.dataSource = "cb" } else if sbOk { self.dataSource = "sb" }
                    self.dataUpdatedAt = self.clockText(at ?? Date())
                    if cbOk { self.cbAt = at }
                    if sbOk { self.sbAt = at }
                    self.cloudNote = self.buildNote(heal: nil)
                    self.poke()
                    self.showToast(okMsg.isEmpty ? msg : okMsg + "（" + msg + "）")
                } else {
                    revert?()
                    self.poke()
                    self.showToast(msg)
                }
            }
        }
    }

    /* ================= 数据读取 ================= */

    /// 两台都读，按 updated_at 取「最新」的那份 —— 而不是「谁先答应用谁」。
    ///
    /// 旧写法是「先问腾讯云，通了就用它，不通才问 Supabase」。可写入端有可能只写上了
    /// 其中一台（腾讯云没登录 / token 过期 / 单台报错），这时读取端如果恰好挑中另一台，
    /// 拿到的就是旧数据 —— 表现出来就是「本机改完，退出再进来又恢复原样」。
    ///
    /// 现在：① 两台都读，谁的时间戳新用谁；② 发现另一台落后而且当前登录着，顺手把最新
    /// 的那份补写过去，让两台自己追平；③ 追不平时把原因写进 cloudNote 显示给用户。
    func load() {
        guard !loading else { return }
        loading = true
        banner = nil
        let cbTok = cbToken
        let sbTok = sbToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var cbSnap: Cloud.Snap? = nil
            var sbSnap: Cloud.Snap? = nil
            cbSnap = try? Cloud.cbReadSnap()
            sbSnap = try? Cloud.sbReadSnap()

            // 时间戳一样（同一台设备一次双写）时以腾讯云为准
            var pick: Cloud.Snap? = nil
            if let c = cbSnap, let s = sbSnap {
                pick = (s.at ?? .distantPast) > (c.at ?? .distantPast) ? s : c
            } else {
                pick = cbSnap ?? sbSnap
            }

            // 两台内容不一致 → 把最新那份补写到落后的那台（前提是那台登录着）。
            // 补写沿用「胜出方」原来的时间戳，而不是当前时间：这样两台写完时间戳就相等，
            // 不会再反复触发补写；万一期间别的设备又写入了更新的版本，也不会被这份补写
            // 盖上（它时间戳更旧，下次读取仍会选中更新的那份）。
            // 判「不一致」要带容差：网页版一次保存分两次写，相差才几毫秒，
            // 不当成不一致，否则每读一次就白写一次。
            var heal: String? = nil
            var healTarget = ""
            var healedAt: Date? = nil
            if let c = cbSnap, let s = sbSnap, !Cloud.sameVersion(c.at, s.at), let p = pick {
                let target = (p.src == "cb") ? "sb" : "cb"
                let tok = (target == "cb") ? cbTok : sbTok
                if !tok.isEmpty {
                    healTarget = target
                    let iso = Cloud.iso(from: p.at)
                    do {
                        if target == "cb" { try Cloud.cbWrite(p.data, token: tok, iso: iso) }
                        else { try Cloud.sbWrite(p.data, token: tok, iso: iso) }
                        healedAt = Cloud.parseIso(iso)
                        heal = "已把最新数据补写到" + (target == "cb" ? "腾讯云" : "Supabase")
                    } catch {
                        heal = (target == "cb" ? "腾讯云" : "Supabase")
                            + "补写失败：" + AppState.translate(error)
                    }
                }
            }

            DispatchQueue.main.async {
                self.loading = false
                self.cbGot = cbSnap != nil
                self.sbGot = sbSnap != nil
                self.cbAt = cbSnap?.at
                self.sbAt = sbSnap?.at
                if let h = healedAt {
                    if healTarget == "cb" { self.cbAt = h } else { self.sbAt = h }
                }

                if let root = pick?.data, let (ps, ws) = M.fromJson(root) {
                    self.persons = ps
                    self.works = ws
                    self.dataSource = pick?.src ?? "local"
                    self.dataUpdatedAt = self.clockText(pick?.at ?? Date())
                    self.saveCache(root)
                } else if self.persons.isEmpty {
                    self.banner = "云端读取失败（腾讯云与 Supabase 均未成功），且本地无缓存"
                }

                self.cloudNote = self.buildNote(heal: heal)
            }
        }
    }

    /// 生成两台一致性提示。空串 = 两边都好好的，不打扰用户。
    /// 只登录一台是最常见也最危险的情况：本机改的东西只写进一台，
    /// 而网页版默认读腾讯云，所以必须显式提醒。
    private func buildNote(heal: String?) -> String {
        /* 只登录一台的风险不在这里说 —— 那是账号问题，由「我的」页账号卡
           （AppState.halfLoginWarning）专门提示，免得两处措辞打架。
           这里只报「数据层面」的不一致。 */
        if cbGot && sbGot, !Cloud.sameVersion(cbAt, sbAt) {
            if let h = heal, !h.isEmpty { return h }
            let cbNewer = (cbAt ?? .distantPast) > (sbAt ?? .distantPast)
            return (cbNewer ? "Supabase" : "腾讯云") + "的数据比另一台旧"
        }
        return ""
    }

    /* ================= 本地缓存 ================= */

    private var cacheUrl: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("xinghai.json")
    }

    private func loadCache() {
        guard let url = cacheUrl, let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let (ps, ws) = M.fromJson(root) else { return }
        persons = ps
        works = ws
        dataSource = "cache"
    }

    private func saveCache(_ root: [String: Any]) {
        guard let url = cacheUrl,
              let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /* ================= 登录 / 退出 ================= */

    /// mode: 0=腾讯云 1=Supabase 2=双端（腾讯云侧自动用 @ 前缀作用户名）
    /// remember: 是否「保持登录状态」（勾上才把 token 落盘）
    func login(email: String, password: String, mode: Int, remember: Bool = true,
               done: @escaping (String) -> Void) {
        self.remember = remember
        d.set(remember, forKey: "remember_login")
        let user = String(email.split(separator: "@").first.map(String.init) ?? email)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var parts: [String] = []

            if mode == 0 || mode == 2 {
                do {
                    let a = try Cloud.cbSignIn(username: user, password: password)
                    // 与安卓端一致：管理员校验失败不阻断登录（否则网络抖动会被误报成登录失败）
                    let admin = (try? Cloud.cbIsAdmin(uid: a.uid, token: a.token)) ?? false
                    self.cbToken = a.token
                    self.cbRefresh = a.refresh
                    self.setMeta("cb_user", user)
                    self.setMeta("cb_admin", admin)
                    DispatchQueue.main.async {
                        self.cbUser = user
                        self.cbAdmin = admin
                    }
                    parts.append(admin ? "腾讯云：管理员登录成功" : "腾讯云：登录成功（非管理员）")
                } catch {
                    parts.append("腾讯云失败：" + AppState.translate(error))
                }
            }

            if mode == 1 || mode == 2 {
                do {
                    let a = try Cloud.sbSignIn(email: email, password: password)
                    let admin = (try? Cloud.sbIsAdmin(uid: a.uid, token: a.token)) ?? false
                    self.sbToken = a.token
                    self.sbRefresh = a.refresh
                    self.setMeta("sb_user", a.user)
                    self.setMeta("sb_admin", admin)
                    DispatchQueue.main.async {
                        self.sbUser = a.user
                        self.sbAdmin = admin
                    }
                    parts.append(admin ? "Supabase：管理员登录成功" : "Supabase：登录成功（非管理员）")
                } catch {
                    parts.append("Supabase 失败：" + AppState.translate(error))
                }
            }

            let result = parts.isEmpty ? "未选择登录方式" : parts.joined(separator: "\n")
            DispatchQueue.main.async { done(result) }
        }
    }

    func logout() {
        memTok.removeAll()
        for k in ["cb_token", "cb_refresh", "cb_user", "cb_admin",
                  "sb_token", "sb_refresh", "sb_user", "sb_admin"] {
            d.removeObject(forKey: k)
        }
        cbUser = nil; cbAdmin = false
        sbUser = nil; sbAdmin = false
    }

    static func translate(_ e: Error) -> String {
        if let ce = e as? CloudError { return ce.msg }
        let s = e.localizedDescription
        if s.contains("offline") || s.contains("internet") { return "网络不可用" }
        if s.contains("timed out") { return "连接超时" }
        return s
    }
}
