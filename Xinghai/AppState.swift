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

    private let d = UserDefaults.standard

    var cbToken: String {
        get { d.string(forKey: "cb_token") ?? "" }
        set { d.set(newValue.isEmpty ? nil : newValue, forKey: "cb_token") }
    }
    var cbRefresh: String {
        get { d.string(forKey: "cb_refresh") ?? "" }
        set { d.set(newValue.isEmpty ? nil : newValue, forKey: "cb_refresh") }
    }
    var sbToken: String {
        get { d.string(forKey: "sb_token") ?? "" }
        set { d.set(newValue.isEmpty ? nil : newValue, forKey: "sb_token") }
    }
    var sbRefresh: String {
        get { d.string(forKey: "sb_refresh") ?? "" }
        set { d.set(newValue.isEmpty ? nil : newValue, forKey: "sb_refresh") }
    }

    var isLoggedIn: Bool { cbUser != nil || sbUser != nil }
    var isAdmin: Bool { cbAdmin || sbAdmin }
    var loginLabel: String {
        if cbUser != nil && sbUser != nil { return "腾讯云 + Supabase" }
        if cbUser != nil { return "腾讯云" }
        if sbUser != nil { return "Supabase" }
        return ""
    }

    var totalCourses: Int {
        persons.reduce(0) { $0 + $1.courses.count }
    }

    var sourceLabel: String {
        switch dataSource {
        case "cb": return "腾讯云"
        case "sb": return "Supabase"
        case "cache": return "本地缓存"
        default: return "内置数据"
        }
    }

    private init() {
        if let u = d.string(forKey: "cb_user") {
            cbUser = u
            cbAdmin = d.bool(forKey: "cb_admin")
        }
        if let u = d.string(forKey: "sb_user") {
            sbUser = u
            sbAdmin = d.bool(forKey: "sb_admin")
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
    func saveData(_ okMsg: String, revert: (() -> Void)? = nil) {
        guard !saving else {
            revert?()
            showToast("正在保存，请稍候")
            return
        }
        saving = true
        let personsSnapshot = persons
        let worksSnapshot = works
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let payload = M.toJson(persons: personsSnapshot, works: worksSnapshot)
            var cbOk = false, sbOk = false
            var cbMsg = "未登录腾讯云", sbMsg = "未登录 Supabase"
            if !self.cbToken.isEmpty {
                do { try Cloud.cbWrite(payload, token: self.cbToken); cbOk = true }
                catch { cbMsg = AppState.translate(error) }
            }
            if !self.sbToken.isEmpty {
                do { try Cloud.sbWrite(payload, token: self.sbToken); sbOk = true }
                catch { sbMsg = AppState.translate(error) }
            }
            let ok = cbOk || sbOk
            var msg = ""
            if ok {
                if cbOk && sbOk { msg = "已保存到腾讯云 + Supabase" }
                else if cbOk { msg = self.sbToken.isEmpty ? "已保存到腾讯云"
                    : "已保存到腾讯云（Supabase 失败：\(sbMsg)）" }
                else { msg = self.cbToken.isEmpty ? "已保存到 Supabase"
                    : "已保存到 Supabase（腾讯云失败：\(cbMsg)）" }
            } else if self.cbToken.isEmpty && self.sbToken.isEmpty {
                msg = "请先登录再保存"
            } else {
                msg = "保存失败：" + (self.cbToken.isEmpty ? sbMsg : cbMsg)
            }
            DispatchQueue.main.async {
                self.saving = false
                if ok {
                    self.saveCache(payload)
                    if !self.cbToken.isEmpty { self.dataSource = "cb" }
                    else if !self.sbToken.isEmpty { self.dataSource = "sb" }
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    self.dataUpdatedAt = f.string(from: Date())
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

    func load() {
        guard !loading else { return }
        loading = true
        banner = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var src = ""
            var root: [String: Any]? = nil
            if let r = try? Cloud.cbRead() { root = r; src = "cb" }
            if root == nil, let r = try? Cloud.sbRead() { root = r; src = "sb" }
            DispatchQueue.main.async {
                self.loading = false
                if let root = root, let (ps, ws) = M.fromJson(root) {
                    self.persons = ps
                    self.works = ws
                    self.dataSource = src
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    self.dataUpdatedAt = f.string(from: Date())
                    self.saveCache(root)
                } else if self.persons.isEmpty {
                    self.banner = "云端读取失败（腾讯云与 Supabase 均未成功），且本地无缓存"
                }
            }
        }
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
    func login(email: String, password: String, mode: Int, done: @escaping (String) -> Void) {
        let user = String(email.split(separator: "@").first.map(String.init) ?? email)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var parts: [String] = []

            if mode == 0 || mode == 2 {
                do {
                    let a = try Cloud.cbSignIn(username: user, password: password)
                    let admin = try Cloud.cbIsAdmin(uid: a.uid, token: a.token)
                    self.d.set(a.token, forKey: "cb_token")
                    self.d.set(a.refresh, forKey: "cb_refresh")
                    self.d.set(user, forKey: "cb_user")
                    self.d.set(admin, forKey: "cb_admin")
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
                    let admin = try Cloud.sbIsAdmin(uid: a.uid, token: a.token)
                    self.d.set(a.token, forKey: "sb_token")
                    self.d.set(a.refresh, forKey: "sb_refresh")
                    self.d.set(a.user, forKey: "sb_user")
                    self.d.set(admin, forKey: "sb_admin")
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
