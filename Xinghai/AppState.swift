import Foundation
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var persons: [Person] = []
    @Published var works: [WorkRow] = []
    @Published var dataSource = "local"   // "cb" / "sb" / "cache" / "local"
    @Published var dataUpdatedAt = ""
    @Published var loading = false
    /// 同步进行到哪一步、已经等了多久。以前只有一句「同步中…」，跨境那条链路
    /// 慢起来能等十几秒，界面一动不动，用户以为卡死了 —— 必须让他看见「还活着」。
    @Published var syncStage = ""
    @Published var syncElapsed = 0
    private var syncTick: DispatchSourceTimer? = nil
    /// 同步途中登录成功 → 记下来，等这轮结束再补一次同步（否则状态卡是旧 token 的结果）
    private var pendingReload = false
    @Published var banner: String? = nil

    /* ---- 落后那台的「待补写」队列：腾讯云优先，跨境那台后台静默补 ---- */
    /// 界面用：现在还有哪些台没写上（"cb" / "sb"）
    @Published var pendingTargets: [String] = []
    /// 最近一次补写为什么没成（空串 = 队列是空的或还没失败过）
    @Published var pendingNote = ""
    /// 目标 → ["iso": 时间戳, "data": 整份快照]。只保留最新一份，幂等，不会堆积。
    private var pending: [String: [String: Any]] = [:]
    private var pushAttempt = 0
    private var pushTimer: DispatchWorkItem? = nil
    private var flushing = false
    /// 重试节奏（秒）：先密后疏，封顶 15 分钟。
    /// 跨境那台「有访问时效」，不能高频戳；但也别等到用户下次打开才补。
    private let pushBackoff: [Double] = [5, 15, 45, 120, 300, 900]

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
    /// 两台各自读取失败的原因（成功则空串）。
    /// 以前这里是 `try? Cloud.sbReadSnap()` —— 失败静默变 nil，界面上只剩「取不到」三个字，
    /// 用户和我们都没法判断到底是断网、超时、连接被重置还是 401。必须把原因留下来。
    @Published var cbErr = ""
    @Published var sbErr = ""
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
        /* 上次没写成功的那些改动要先捡回来：凭证也在，续期之后就能补上。 */
        loadPending()
        // 顺序不能反：先把登录态续上（access_token 只有 2 小时），再去读云端。
        // 续期结束会回调 load()，缓存已经先上屏了，所以用户看不到空档。
        renewSession { [weak self] in self?.load() }
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

    /* ================= 同步秒表 ================= */

    /// 「同步中…」要会走秒。跨境那条链路慢起来十几秒，文字一动不动时用户只能
    /// 猜是不是死机了；秒数一跳，立刻就说明「还活着、在等网络」。
    private func startSyncTick() {
        syncTick?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self = self, self.loading else { return }
            self.syncElapsed += 1
        }
        t.resume()
        syncTick = t
    }

    private func stopSyncTick() {
        syncTick?.cancel()
        syncTick = nil
    }

    /* ================= 待补写队列 ================= */

    /// 队列落盘。进程被杀、切后台被回收都不该丢掉「还欠一次写」这件事。
    private var pendingUrl: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("pending.json")
    }

    private func loadPending() {
        guard pending.isEmpty, let url = pendingUrl, let d = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]]
        else { return }
        pending = j
        pendingTargets = pending.keys.sorted()
        if !pending.isEmpty { schedulePush(after: 1) }   // 一启动就试一次，不打扰用户
    }

    private func savePending() {
        guard let url = pendingUrl else { return }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let d = try? JSONSerialization.data(withJSONObject: pending) {
            try? d.write(to: url, options: .atomic)
        }
    }

    /// 记下「这台没写上」，稍后在后台补。同一台只留最新一份快照（后到的覆盖先到的）。
    private func enqueue(_ target: String, data: [String: Any], iso: String) {
        pending[target] = ["iso": iso, "data": data]
        savePending()
        pendingTargets = pending.keys.sorted()
        schedulePush(after: pushBackoff[min(pushAttempt, pushBackoff.count - 1)])
    }

    private func schedulePush(after delay: Double) {
        pushTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushPending() }
        pushTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 静默补写：把队列里最新那份快照写到各自那台。
    /// 成功 → 出队；失败 → 退避后再来，一直补到成功为止。
    ///
    /// 只在主线程调（自己被 main.asyncAfter / 主线程事件触发），用 `flushing` 串行化，
    /// 免得两次补写交叉把同一台写成新旧两份。
    func flushPending() {
        if flushing { schedulePush(after: 2); return }   // 上一轮还在跑，等它
        guard !pending.isEmpty else { return }
        flushing = true
        let jobs = pending
        let cbTok = cbToken
        let sbTok = sbToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var done: [(String, String)] = []      // (目标, 写出去的 iso)
            var lastErr = ""
            for (target, job) in jobs {
                guard let data = job["data"] as? [String: Any],
                      let iso = job["iso"] as? String else {
                    done.append((target, ""))      // 残缺任务直接丢
                    continue
                }
                let tok = (target == "cb") ? cbTok : sbTok
                if tok.isEmpty {
                    lastErr = (target == "cb" ? "腾讯云" : "Supabase") + "未登录，登录后会自动补写"
                    continue                       // 没登录写不了，留着等登录
                }
                do {
                    if target == "cb" { try Cloud.cbWrite(data, token: tok, iso: iso) }
                    else { try Cloud.sbWrite(data, token: tok, iso: iso) }
                    done.append((target, iso))
                } catch {
                    /* 凭证失效 ≠ 网络抖动：前者要么重新登录，要么一直白试，得说清楚 */
                    if CloudError.isAuthFailure(error) {
                        lastErr = (target == "cb" ? "腾讯云" : "Supabase") + "登录已失效，重新登录后才会补写"
                    } else {
                        lastErr = AppState.translate(error)
                    }
                }
            }
            DispatchQueue.main.async {
                let hadWork = !self.pending.isEmpty
                for (target, iso) in done {
                    /* 比较后再删：写的过程中用户可能又存了一次，
                       此时 pending 里已经是更新的 iso，不能把新的当成写成功了删掉。 */
                    if iso.isEmpty || (self.pending[target]?["iso"] as? String) == iso {
                        self.pending.removeValue(forKey: target)
                    }
                }
                self.savePending()
                self.pendingTargets = self.pending.keys.sorted()
                self.pendingNote = self.pending.isEmpty ? "" : lastErr
                self.flushing = false

                if self.pending.isEmpty {
                    self.pushAttempt = 0
                    if hadWork && !done.isEmpty { self.showToast("已补写到云端，两台已一致") }
                } else {
                    self.pushAttempt += 1
                    self.schedulePush(after: self.pushBackoff[min(self.pushAttempt, pushBackoff.count - 1)])
                }
            }
        }
    }

    /* ================= 保存到云端 ================= */

    /// 乐观更新：调用方先改内存数据，失败时由 revert 回滚现场。
    ///
    /// **写入顺序按「哪台快、哪台稳」定：腾讯云在国内，先写它。** 它成了就立刻告诉
    /// 用户「保存好了」，不必陪着跨境那台干等。跨境那台（Supabase）写不上就进后台
    /// 队列，静默重试到成功为止（见 flushPending）。
    ///
    /// 为什么不能两台都等着：用户那边到 supabase.co 的连接经常被重置，一次保存能卡
    /// 半分钟以上，体感就是「界面死了」，卡住期间还存不了东西。
    ///
    /// **所有 Supabase 写入都走队列**（不再inline 写），不然「先发的慢请求后到」
    /// 会把新的覆盖成旧的 —— 队列是串行的，天然没这个问题。
    ///
    /// 失败语义：腾讯云写不上、且 Supabase 也没登录 → 才算真失败（回滚、不落缓存）。
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
            let at = Cloud.parseIso(iso)
            let head = okMsg.isEmpty ? "已保存" : okMsg

            /* ① 腾讯云先写（快、稳），成了立刻给用户交代 */
            var cbOk = false
            var cbMsg = "腾讯云未登录"
            if !cbTok.isEmpty {
                do { try Cloud.cbWrite(payload, token: cbTok, iso: iso); cbOk = true }
                catch { cbMsg = AppState.translate(error) }
            }

            DispatchQueue.main.async {
                self.saving = false
                if cbOk {
                    self.saveCache(payload)
                    self.dataSource = "cb"
                    self.dataUpdatedAt = self.clockText(at ?? Date())
                    self.cbAt = at
                    self.poke()
                    /* 跨境那台交给后台，不阻塞、也不弹错 */
                    self.enqueue("sb", data: payload, iso: iso)
                    self.cloudNote = self.buildNote(heal: nil)
                    self.showToast(head + "（已保存到腾讯云，正在同步 Supabase…）")
                    self.schedulePush(after: 0.2)          // 正常情况这时就补上了
                    return
                }

                /* 腾讯云没写上：Supabase 也没登录的话，才是真失败 */
                if sbTok.isEmpty {
                    revert?()
                    self.poke()
                    self.showToast(cbTok.isEmpty ? "请先登录再保存" : "保存失败：" + cbMsg)
                    return
                }
                /* 两台都交给队列去重试，本地先当保存成功（改动不会丢） */
                self.saveCache(payload)
                self.enqueue("cb", data: payload, iso: iso)
                self.enqueue("sb", data: payload, iso: iso)
                self.cloudNote = "腾讯云这次没写上（" + cbMsg + "），已在后台自动重试"
                self.poke()
                self.showToast(head + "（腾讯云写入失败，已在后台重试）")
                self.schedulePush(after: 0.2)
            }
        }
    }

    /* ================= 登录态续期 ================= */

    /// 启动时先续期、再拉数据。
    ///
    /// 为什么要这一步：腾讯云 access_token 只有 2 小时，refresh_token 有 30 天。
    /// 之前 iOS 端【完全没有刷新逻辑】，两小时一过 access_token 就静默失效 ——
    /// 界面还理直气壮显示「已登录（管理员）」，可写入腾讯云一律 401，
    /// 改动只落到 Supabase；而读取是「两台都读、取最新的那份」，
    /// 于是用户看到的就是「改了课表像是没改」。
    ///
    /// 现在每次启动（以及登录后）都换一次：换成功就把新 token 存回去；
    /// 换不动（refresh_token 也过期了）就老实把该端登出并提示，绝不假装还登录着。
    /// 结束时一定回调 `done`，由它去拉数据 —— 这样「续期 → 读取」的顺序是有保证的。
    func renewSession(done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var expired: [String] = []
            var offline: [String] = []     // 只是这次没续上（网络问题），凭证留着
            var renewed = false

            if self.cbUser != nil {
                let rf = self.cbRefresh
                if rf.isEmpty {
                    self.forget("cb", "腾讯云")
                    expired.append("腾讯云")
                } else {
                    do {
                        let a = try Cloud.cbRefresh(rf)
                        self.cbToken = a.token
                        if !a.refresh.isEmpty { self.cbRefresh = a.refresh }
                        let admin = (try? Cloud.cbIsAdmin(uid: a.uid, token: a.token)) ?? false
                        self.setMeta("cb_admin", admin)
                        DispatchQueue.main.async { self.cbAdmin = admin }
                        renewed = true
                    } catch {
                        /* 网络问题别清登录态：清了就再也补不回来（用户那边重登不上） */
                        if CloudError.isAuthFailure(error) {
                            self.forget("cb", "腾讯云")
                            expired.append("腾讯云")
                        } else {
                            offline.append("腾讯云")
                        }
                    }
                }
            }

            if self.sbUser != nil {
                let rf = self.sbRefresh
                if rf.isEmpty {
                    self.forget("sb", "Supabase")
                    expired.append("Supabase")
                } else {
                    do {
                        let a = try Cloud.sbRefresh(rf)
                        self.sbToken = a.token
                        if !a.refresh.isEmpty { self.sbRefresh = a.refresh }
                        let admin = (try? Cloud.sbIsAdmin(uid: a.uid, token: a.token)) ?? false
                        self.setMeta("sb_admin", admin)
                        DispatchQueue.main.async { self.sbAdmin = admin }
                        renewed = true
                    } catch {
                        /* 网络问题别清登录态 —— 见 CloudError.isAuthFailure 的说明 */
                        if CloudError.isAuthFailure(error) {
                            self.forget("sb", "Supabase")
                            expired.append("Supabase")
                        } else {
                            offline.append("Supabase")
                        }
                    }
                }
            }

            if !expired.isEmpty {
                DispatchQueue.main.async {
                    self.showToast("⚠ " + expired.joined(separator: " / ")
                        + "登录已过期，请重新登录；否则改动只会写进另一台")
                }
            }
            if !offline.isEmpty {
                /* 只是没连上，凭证还在。不说清楚的话，用户会以为又掉登录了。 */
                DispatchQueue.main.async {
                    self.pendingNote = offline.joined(separator: " / ")
                        + "这次没连上（凭证已保留，稍后自动重试）"
                }
            }
            if renewed { DispatchQueue.main.async { self.poke() } }
            DispatchQueue.main.async {
                done?()
                // 续期之后立刻把还没补上的写出去（跨境那台连上了就能收尾）
                self.flushPending()
            }
        }
    }

    /// 某一端彻底失效：清掉它的凭证，让界面老实显示「未登录」
    private func forget(_ who: String, _ label: String) {
        if who == "cb" {
            cbToken = ""; cbRefresh = ""
            setMeta("cb_user", nil); setMeta("cb_admin", nil)
            DispatchQueue.main.async { self.cbUser = nil; self.cbAdmin = false }
        } else {
            sbToken = ""; sbRefresh = ""
            setMeta("sb_user", nil); setMeta("sb_admin", nil)
            DispatchQueue.main.async { self.sbUser = nil; self.sbAdmin = false }
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
    /// - Parameter manual: 是否用户手动点的「立即同步」。手动一定要给结束回话；
    ///   启动时的自动同步只在失败或明显慢时才出声，免得每次开 App 都弹一句。
    func load(manual: Bool = false) {
        /* 同步途中再点一次，以前是 `guard !loading else { return }` 直接吞掉 ——
           用户点了几下毫无反应，只能干等。现在明确回一句正在干什么。 */
        guard !loading else {
            showToast(syncStage.isEmpty ? "正在同步，请稍候…"
                                        : "正在同步（" + syncStage + "），请稍候…")
            return
        }
        loading = true
        syncStage = "正在读取云端数据…"
        syncElapsed = 0
        startSyncTick()
        banner = nil
        let cbTok = cbToken
        let sbTok = sbToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var cbSnap: Cloud.Snap? = nil
            var sbSnap: Cloud.Snap? = nil
            var cbErr = "", sbErr = ""
            /* 两台【并行】读。串行时总耗时 = 腾讯云 + Supabase，而跨境那条常常是慢的
               那一个，等于白等两份时间；并行后约等于较慢的那一台，等待直接砍半。 */
            let box = NSLock()
            let grp = DispatchGroup()
            grp.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var s: Cloud.Snap? = nil
                var e = ""
                do { s = try Cloud.cbReadSnap() } catch { e = AppState.translate(error) }
                box.lock(); cbSnap = s; cbErr = e; box.unlock()
                grp.leave()
            }
            grp.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var s: Cloud.Snap? = nil
                var e = ""
                do { s = try Cloud.sbReadSnap() } catch { e = AppState.translate(error) }
                box.lock(); sbSnap = s; sbErr = e; box.unlock()
                grp.leave()
            }
            grp.wait()

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
                    let targetLabel = (target == "cb") ? "腾讯云" : "Supabase"
                    DispatchQueue.main.async { self.syncStage = "正在把最新数据补写到" + targetLabel + "…" }
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
                let secs = self.syncElapsed
                self.stopSyncTick()
                self.loading = false
                self.syncStage = ""
                self.cbGot = cbSnap != nil
                self.sbGot = sbSnap != nil
                self.cbErr = cbErr
                self.sbErr = sbErr
                self.cbAt = cbSnap?.at
                self.sbAt = sbSnap?.at
                if let h = healedAt {
                    if healTarget == "cb" { self.cbAt = h } else { self.sbAt = h }
                }

                var parsed = true
                if let root = pick?.data, let (ps, ws) = M.fromJson(root) {
                    self.persons = ps
                    self.works = ws
                    self.dataSource = pick?.src ?? "local"
                    self.dataUpdatedAt = self.clockText(pick?.at ?? Date())
                    self.saveCache(root)
                } else if self.persons.isEmpty {
                    self.banner = "云端读取失败（腾讯云与 Supabase 均未成功），且本地无缓存"
                    parsed = false
                }

                self.cloudNote = self.buildNote(heal: heal)

                /* 同步途中登录成功 → 这轮用的是旧 token，立刻再同步一次。
                   否则用户会看到「刚登录」和「状态还是未登录」打脸。 */
                if self.pendingReload {
                    self.pendingReload = false
                    self.load()
                    return
                }

                /* 结束一定要有回话。以前同步完一声不吭，用户不知道好了没有。 */
                let both = self.cbGot && self.sbGot
                guard manual || secs >= 3 || !both else { return }
                if !self.pendingTargets.isEmpty {
                    self.showToast("同步完成，但还有「"
                        + self.pendingTargets.map { $0 == "cb" ? "腾讯云" : "Supabase" }.joined(separator: " / ")
                        + "」待补写，正在后台重试")
                } else if both && parsed {
                    self.showToast("同步完成：两台数据已核对")
                } else if !self.cbGot && !self.sbGot {
                    self.showToast("同步失败：两台服务器都没读到（见上方状态）")
                } else {
                    self.showToast("同步完成，但有 1 台没读到（见上方状态）")
                }
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
            DispatchQueue.main.async {
                /* 登录成功时若正好在同步，那这一轮用的是登录前的旧凭证 ——
                   记下来，等它收尾后自动再同步一次，免得状态卡仍显示「未登录」。 */
                if self.loading && !parts.isEmpty && !parts.allSatisfy({ $0.contains("失败") }) {
                    self.pendingReload = true
                }
                done(result)
                /* 登录成功 = 队列里那台现在能写了，立刻把欠的补上 */
                if !parts.isEmpty && !parts.allSatisfy({ $0.contains("失败") }) {
                    self.flushPending()
                }
            }
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

    /// 把底层网络异常翻成人话（与安卓端 Net.human 对齐）。
    /// 以前 "The network connection was lost." 会原样透传，用户只会以为云端坏了。
    static func translate(_ e: Error) -> String {
        if let ce = e as? CloudError { return ce.msg }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "网络不可用"
            case .timedOut: return "网络超时，请重试"
            case .cannotFindHost: return "网络不可用（域名解析不了）"
            case .cannotConnectToHost: return "连不上服务器"
            case .networkConnectionLost: return "网络连接被重置（网络波动，请再试一次）"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "安全连接失败（SSL）"
            default: break
            }
        }
        let s = e.localizedDescription
        let low = s.lowercased()
        if low.contains("offline") || low.contains("internet") { return "网络不可用" }
        if low.contains("timed out") || low.contains("timeout") { return "网络超时，请重试" }
        if low.contains("connection reset") || low.contains("connection was lost")
            || low.contains("network connection was lost") { return "网络连接被重置（网络波动，请再试一次）" }
        if low.contains("could not connect") || low.contains("connection refused") { return "连不上服务器" }
        return s
    }
}
