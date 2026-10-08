import Foundation

enum CloudError: Error {
    case badUrl
    case badResponse
    case http(Int, String)

    var msg: String {
        switch self {
        case .badUrl: return "地址无效"
        case .badResponse: return "服务器响应异常"
        case .http(_, let m):
            let low = m.lowercased()
            if low.contains("invalid login credentials") { return "邮箱或密码错误" }
            if low.contains("failed to fetch") || low.contains("network") { return "网络连接失败" }
            return m.isEmpty ? "请求被拒绝" : m
        }
    }
}

/// 极简 HTTP（全同步，调用方自行放后台线程）
enum Net {
    static func get(_ url: String, _ headers: [String: String]) throws -> String {
        try request(url, "GET", headers, nil)
    }

    static func post(_ url: String, _ headers: [String: String], _ body: String) throws -> String {
        try request(url, "POST", headers, body)
    }

    private static func request(_ urlStr: String, _ method: String,
                                _ headers: [String: String], _ body: String?) throws -> String {
        guard let url = URL(string: urlStr) else { throw CloudError.badUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        // 与安卓端 Net.java 对齐：Accept 始终带；有 body 时必须声明 JSON，
        // 否则 Supabase(GoTrue) 回 "Could not parse request body as JSON"，
        // 腾讯云网关的 OIDC 层也会解析失败。
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            req.httpBody = body.data(using: .utf8)
        }

        var outData: Data?
        var outStatus = 0
        var outError: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error {
                outError = error
            } else {
                outData = data
                outStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            }
            sem.signal()
        }.resume()
        sem.wait()

        if let e = outError { throw e }
        let text = String(data: outData ?? Data(), encoding: .utf8) ?? ""
        if outStatus >= 400 {
            throw CloudError.http(outStatus, errorMessage(text))
        }
        return text
    }

    private static func errorMessage(_ body: String) -> String {
        if let d = body.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for key in ["msg", "message", "error_description", "error"] {
                if let s = o[key] as? String { return s }
            }
        }
        return body.count > 120 ? String(body.prefix(120)) + "…" : body
    }
}

func jsonBody(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// 云端后端：腾讯云 CloudBase（首选） + Supabase（备用）。全部走 REST。
enum Cloud {

    static let cbEnv = "xh-yjxcb-d6g4mu0b64c1e26e5"
    static let cbBase = "https://" + cbEnv + ".api.tcloudbasegateway.com"
    static let cbKey =
        "eyJhbGciOiJSUzI1NiIsImtpZCI6IjNlZmNiZGMwLWJmODQtNGMwZC1iNzMyLTU2YWI5ODY5YjViOCJ9.eyJpc3MiOiJodHRwczovL3hoLXlqeGNiLWQ2ZzRtdTBiNjRjMWUyNmU1LmFwLXNoYW5naGFpLnRjYi1hcGkudGVuY2VudGNsb3VkYXBpLmNvbSIsInN1YiI6ImFub24iLCJhdWQiOiJ4aC15anhjYi1kNmc0bXUwYjY0YzFlMjZlNSIsImV4cCI6NDA5NDk1OTYzNCwiaWF0IjoxNzkxMjc2NDM0LCJub25jZSI6InpFMVNUYnJWUTMyVGhBejNrNFhiM0EiLCJhdF9oYXNoIjoiekUxU1RiclZRMzJUaEF6M2s0WGIzQSIsIm5hbWU" +
        "iOiJBbm9ueW1vdXMiLCJzY29wZSI6ImFub255bW91cyIsInByb2plY3RfaWQiOiJ4aC15anhjYi1kNmc0bXUwYjY0YzFlMjZlNSIsIm1ldGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJyb2xlIjoiYW5vbiIsImlzX2Fub255bW91cyI6dHJ1ZSwiYXBwX21ldGFkYXRhIjp7InByb3ZpZGVyIjoiYW5vbnltb3VzIiwicHJvdmlkZXJzIjpbImFub255bW91cyJdfSwidXNlcl9tZXRhZGF0YSI6eyJuYW1lIjoiQW5vbnltb3VzIn0sInVzZXJfdHlwZSI6IiIsImNsaWVudF90eXBlIjoiY2xpZW50X3VzZXIiLCJpc19zeXN" +
        "0ZW1fYWRtaW4iOmZhbHNlfQ.Drl3zM75XGMK_xkSRgJTIGZzy6xdT4sYajQft6euKeCwUC0Vzc0NAti4V8L3fVt9GYZlN2txkkoG4CMrMuGfNPY7ZFZJ8MdWxtPdMyTKyGh4pzbTa5LVJo4TBgZYt1rdd1lup2XS8mMdfvOVjPCiMrBiLlyErEAhdnB9LXx53KDGSXqqt_lyopRMWOBH_B9o-bRO4DQC5s15zWRoLQ6ZeikM32UHIw__bs3HtvVtSpU7yLm9dlkUgkUH0tbHmCa06srVzK4ZANbaUhnfex7y32q6nR5xbRQgnCppz04j-OgimFb79XT7GJ7z4dGhDVMwFyJVStR6C69ApBDkfjAkWw"

    static let sbUrl = "https://jcaobupbubldipbrzfuo.supabase.co"
    static let sbKey = "sb_publishable_B0aV4XzeALxax8YqzedegQ_ZBu-ewgD"

    // 表结构：timetable_state(id=1 单行存全量 data) + admins(user_id 白名单)

    struct Auth {
        var token = ""
        var uid = ""
        var user = ""
        var refresh = ""
    }

    /// 一次读取的结果：数据 + 这份数据是什么时候写的 + 来自哪台服务器。
    /// 「什么时候写的」是判断两台谁更新的唯一依据——以前只看「谁先答应用谁」，
    /// 结果只往 Supabase 写、却优先读腾讯云，本机改完一重进就「恢复原样」。
    struct Snap {
        var data: [String: Any]
        var at: Date?          // updated_at；解析不出来按「最旧」算
        var src: String        // "cb" / "sb"
    }

    private static func cbHeaders(_ token: String?) -> [String: String] {
        ["apikey": cbKey,
         "Authorization": "Bearer " + (token ?? cbKey),
         "x-ty-id": "cloudbase"]
    }

    private static func sbHeaders(_ token: String?) -> [String: String] {
        ["apikey": sbKey,
         "Authorization": "Bearer " + (token ?? sbKey)]
    }

    private static func nowIso() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// 对外暴露：写两台时共用同一个时间戳，两台才能比对出「谁更新」
    static func nowIsoText() -> String { nowIso() }

    /// 解析 PostgREST 的时间戳，形如 2026-10-08T05:03:42.221+00:00 / ...+08:00 / ...Z
    /// 用 ISO8601DateFormatter 会挑格式，这里两种分别试，都失败则返回 nil（按最旧算）。
    static func parseIso(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// PostgREST 返回 [{...}]，取出第一行的 data 字段
    private static func rowOf(_ body: String) -> [String: Any]? {
        guard let d = body.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]],
              let row = arr.first else { return nil }
        return row
    }

    private static func dataOf(_ row: [String: Any]) -> [String: Any]? {
        if let o = row["data"] as? [String: Any] { return o }
        if let s = row["data"] as? String,
           let sd = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: sd)) as? [String: Any] {
            return o
        }
        return nil
    }

    private static func pickData(_ body: String) -> [String: Any]? {
        guard let row = rowOf(body) else { return nil }
        return dataOf(row)
    }

    /// 连 data 带 updated_at 一起取
    private static func pickSnap(_ body: String, _ src: String) -> Snap? {
        guard let row = rowOf(body), let data = dataOf(row) else { return nil }
        return Snap(data: data, at: parseIso(row["updated_at"] as? String), src: src)
    }

    /* ================= 读取 ================= */

    static func cbRead() throws -> [String: Any]? {
        try pickData(Net.get(cbBase + "/v1/rdb/rest/timetable_state?select=data&id=eq.1",
                             cbHeaders(nil)))
    }

    static func sbRead() throws -> [String: Any]? {
        try pickData(Net.get(sbUrl + "/rest/v1/timetable_state?select=data&id=eq.1",
                             sbHeaders(nil)))
    }

    /// 带时间戳的读取：两台都读，比出谁最新
    static func cbReadSnap() throws -> Snap? {
        try pickSnap(Net.get(cbBase + "/v1/rdb/rest/timetable_state?select=data,updated_at&id=eq.1",
                             cbHeaders(nil)), "cb")
    }

    static func sbReadSnap() throws -> Snap? {
        try pickSnap(Net.get(sbUrl + "/rest/v1/timetable_state?select=data,updated_at&id=eq.1",
                             sbHeaders(nil)), "sb")
    }

    /* ================= 写入 ================= */

    static func cbWrite(_ data: [String: Any], token: String?) throws {
        try cbWrite(data, token: token, iso: nowIso())
    }

    /// iso 由调用方统一生成：两台写同一份数据必须用同一个时间戳，否则「谁更新」会漂
    static func cbWrite(_ data: [String: Any], token: String?, iso: String) throws {
        var h = cbHeaders(token)
        h["Prefer"] = "resolution=merge-duplicates,return=minimal"
        _ = try Net.post(cbBase + "/v1/rdb/rest/timetable_state", h,
                         jsonBody(["id": 1, "data": data, "updated_at": iso]))
    }

    static func sbWrite(_ data: [String: Any], token: String?) throws {
        try sbWrite(data, token: token, iso: nowIso())
    }

    static func sbWrite(_ data: [String: Any], token: String?, iso: String) throws {
        var h = sbHeaders(token)
        h["Prefer"] = "resolution=merge-duplicates,return=minimal"
        _ = try Net.post(sbUrl + "/rest/v1/timetable_state?on_conflict=id", h,
                         jsonBody(["id": 1, "data": data, "updated_at": iso]))
    }

    /* ================= 登录 ================= */

    static func cbSignIn(username: String, password: String) throws -> Auth {
        let out = try Net.post(cbBase + "/auth/v1/signin", cbHeaders(nil),
                               jsonBody(["username": username, "password": password]))
        guard let d = out.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw CloudError.badResponse
        }
        var a = Auth()
        a.token = j["access_token"] as? String ?? ""
        a.uid = j["sub"] as? String ?? ""
        a.refresh = j["refresh_token"] as? String ?? ""
        a.user = username
        if a.token.isEmpty { throw CloudError.badResponse }
        if a.uid.isEmpty { a.uid = uidFromJwt(a.token) }
        return a
    }

    static func sbSignIn(email: String, password: String) throws -> Auth {
        let out = try Net.post(sbUrl + "/auth/v1/token?grant_type=password", sbHeaders(nil),
                               jsonBody(["email": email, "password": password]))
        guard let d = out.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw CloudError.badResponse
        }
        var a = Auth()
        a.token = j["access_token"] as? String ?? ""
        a.refresh = j["refresh_token"] as? String ?? ""
        if let u = j["user"] as? [String: Any] {
            a.uid = u["id"] as? String ?? ""
            a.user = u["email"] as? String ?? email
        } else {
            a.user = email
        }
        if a.token.isEmpty { throw CloudError.badResponse }
        return a
    }

    /// 从 JWT 的 payload 里取 sub
    static func uidFromJwt(_ jwt: String) -> String {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return "" }
        var b64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        return j["sub"] as? String ?? ""
    }

    /* ================= 管理员校验 ================= */

    static func cbIsAdmin(uid: String, token: String?) throws -> Bool {
        guard !uid.isEmpty else { return false }
        let body = try Net.get(cbBase + "/v1/rdb/rest/admins?select=user_id&user_id=eq." + uid,
                                cbHeaders(token))
        return adminHit(body)
    }

    static func sbIsAdmin(uid: String, token: String?) throws -> Bool {
        guard !uid.isEmpty else { return false }
        let body = try Net.get(sbUrl + "/rest/v1/admins?select=user_id&user_id=eq." + uid,
                                sbHeaders(token))
        return adminHit(body)
    }

    private static func adminHit(_ body: String) -> Bool {
        guard let d = body.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return false }
        return !arr.isEmpty
    }
}
