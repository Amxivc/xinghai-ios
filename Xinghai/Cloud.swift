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
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body { req.httpBody = body.data(using: .utf8) }

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
        "eyJhbGciOiJSUzI1NiIsImtpZCI6IjNlZmNiZGMwLWJmODQtNGMwZC1iNzMyLTU2YWI5ODY5YjViOCJ9." +
        "eyJpc3MiOiJodHRwczovL3hoLXlqeGNiLWQ2ZzRtdTBiNjRjMWUyNmU1LmFwLXNoYW5naGFpLnRjYi1hcGkudGVuY2VudGNsb3VkYXBpLmNvbSIsInN1YiI6ImFub24iLCJhdWQiOiJ4aC15anhjYi1kNmc0bXUwYjY0YzFlMjZlNSIsImV4cCI6NDA5NDk1OTYzNCwiaWF0IjoxNzkxMjc2NDM0LCJub25jZSI6InpFMVNUYnJWUTMyVGhBejNrNFhiM0EiLCJhdF9oYXNoIjoiekUxU1RiclZRMzJUaEF6M2s0WGIzQSIsIm5hbWUiOiJBbm9ueW1vdXMiLCJzY29wZSI6ImFub255bW91cyIsInByb2plY3RfaWQiOiJ4aC15anhjYi1kNmc0bXUwYjY0YzFlMjZlNSIsIm1ldGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJyb2xlIjoiYW5vbnltb3VzIiwiaXNfYW5vbnltb3VzIjp0cnVlLCJhcHBfbWV0YWRhdGEiOnsicHJvdmlkZXIiOiJhbm9ueW1vdXMiLCJwcm92aWRlcnMiOlsiYW5vbnltb3VzIl19LCJ1c2VyX21ldGFkYXRhIjp7Im5hbWUiOiJBbm9ueW1vdXNInSwidXNlcl90eXBlIjoiIiwiY2xpZW50X3R5cGUiOiJjbGllbnRfdXNlciIsImlzX3N5c3RlbV9hZG1pbiI6ZmFsc2V9." +
        "Drl3zM75XGMK_xkSRgJTIGZzy6xdT4sYajQft6euKeCwUC0Vzc0NAti4V8L3fVt9GYZlN2txkkoG4CMrMuGfNPY7ZFZJ8MdWxtPdMyTKyGh4pzbTa5LVJo4TBgZYt1rdd1lup2XS8mMdfvOVjPCiMrBiLlyErEAhdnB9LXx53KDGSXqqt_lyopRMWOBH_B9o-bRO4DQC5s15zWRoLQ6ZeikM32UHIw__bs3HtvVtSpU7yLm9dlkUgkUH0tbHmCa06srVzK4ZANbaUhnfex7y32q6nR5xbRQgnCppz04j-OgimFb79XT7GJ7z4dGhDVMwFyJVStR6C69ApBDkfjAkWw"

    static let sbUrl = "https://jcaobupbubldipbrzfuo.supabase.co"
    static let sbKey = "sb_publishable_B0aV4XzeALxax8YqzedegQ_ZBu-ewgD"

    // 表结构：timetable_state(id=1 单行存全量 data) + admins(user_id 白名单)

    struct Auth {
        var token = ""
        var uid = ""
        var user = ""
        var refresh = ""
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

    /// PostgREST 返回 [{...}]，取出第一行的 data 字段
    private static func pickData(_ body: String) -> [String: Any]? {
        guard let d = body.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]],
              let row = arr.first else { return nil }
        if let o = row["data"] as? [String: Any] { return o }
        if let s = row["data"] as? String,
           let sd = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: sd)) as? [String: Any] {
            return o
        }
        return nil
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

    /* ================= 写入 ================= */

    static func cbWrite(_ data: [String: Any], token: String?) throws {
        var h = cbHeaders(token)
        h["Prefer"] = "resolution=merge-duplicates,return=minimal"
        _ = try Net.post(cbBase + "/v1/rdb/rest/timetable_state", h,
                         jsonBody(["id": 1, "data": data, "updated_at": nowIso()]))
    }

    static func sbWrite(_ data: [String: Any], token: String?) throws {
        var h = sbHeaders(token)
        h["Prefer"] = "resolution=merge-duplicates,return=minimal"
        _ = try Net.post(sbUrl + "/rest/v1/timetable_state?on_conflict=id", h,
                         jsonBody(["id": 1, "data": data, "updated_at": nowIso()]))
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
