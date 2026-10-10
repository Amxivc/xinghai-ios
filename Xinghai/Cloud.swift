import Foundation
import Network
import Security

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

    /// 这个错误是「凭证真的失效」吗？**只有它才配把登录态清掉。**
    ///
    /// 以前续期失败一律 `forget()`，可网络抖动（超时 / 连接被重置 / 域名解析不了）
    /// 走的是同一个 catch —— 信号一差就把 Supabase 的登录凭证抹掉，之后再也补不回来
    /// （用户那边又登不上 Supabase），表现成「只有这一台，登不登录都读不到那边的数据」，
    /// 而且每次启动都会再抹一遍。必须分开：
    ///   401/403、invalid_grant / invalid_token / refresh_token_not_found … → 真失效
    ///   其余（URLError、5xx、空响应）→ 网络问题，**凭证原样保留**，稍后重试。
    static func isAuthFailure(_ e: Error) -> Bool {
        guard let ce = e as? CloudError else { return false }
        guard case .http(let code, let body) = ce else { return false }
        if code == 401 || code == 403 { return true }
        let low = body.lowercased()
        for k in ["invalid_grant", "invalid_token", "refresh_token_not_found",
                  "token has expired", "invalid jwt", "invalid claim",
                  "invalid login credentials", "user_not_found"] where low.contains(k) {
            return true
        }
        return false
    }
}

/// 走 DNS over HTTPS 解析域名，绕开被污染的运营商 DNS。
///
/// **为什么要它**（2026-10-09 实体机实测）：
/// 同一台 iPhone、同一张中国移动 5G 卡，腾讯云（国内节点）秒连，
/// 而 `jcaobupbubldipbrzfuo.supabase.co`（Cloudflare 境外节点）一直
/// `URLError.timedOut` —— 换 WiFi 也一样。安卓端、网页端在同一时段却正常。
/// 服务器本身没问题（本机实测 DNS 11ms / TCP 153ms / TLS 379ms / REST 200，
/// 登录、续期、anon 读取全 200）。差别就在「把这个域名解析成哪个 IP」：
/// 运营商递归 DNS 在这种网络下会给出不可达的 Cloudflare 边缘节点，连过去就一直等。
///
/// 解法：自己用 **国内可达的 DoH**（阿里 dns.alidns.com，实测可解析）拿 A 记录，
/// 再交给 `Net.rawHttps` 用 NWConnection 直连 —— 那里能把「连哪个 IP」和
/// 「TLS SNI 报哪个域名」分开指定，证书校验照常通过。
/// 不需要任何私有 API，也不需要改系统设置。
///
/// 全部失败时返回兜底 IP 表，调用方仍会照常尝试，行为不比改动前差。
enum SbDns {
    /// DoH 端点（按可用性排序）。1.1.1.1 在国内常常连不上，所以放最后。
    private static let doh = [
        "https://dns.alidns.com/resolve?name=%@&type=A",
        "https://doh.pub/dns-query?name=%@&type=A",
    ]

    /// 兜底 IP：Cloudflare 给 Supabase 分配的边缘节点，本机实测两个都 200。
    /// 放在这里是为了「DoH 本身也连不上」时不至于无路可走。
    static let fallback = ["104.18.38.10", "172.64.149.246"]

    private static var cached: [String: [String]] = [:]
    private static var cachedAt: [String: Date] = [:]
    private static let ttl: TimeInterval = 600        // 10 分钟
    private static let lock = NSLock()

    /// 取某个域名的 A 记录。命中缓存直接返回；否则走 DoH，再不行用兜底表。
    static func ips(for host: String) -> [String] {
        lock.lock()
        if let at = cachedAt[host], Date().timeIntervalSince(at) < ttl,
           let v = cached[host], !v.isEmpty {
            lock.unlock()
            return v
        }
        lock.unlock()

        var found: [String] = []
        for tpl in doh {
            guard let enc = host.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) else { continue }
            let u = String(format: tpl, enc)
            if let body = try? plainGet(u) {
                let ips = parseAnswers(body)
                if !ips.isEmpty { found = ips; break }
            }
        }
        if found.isEmpty { found = fallback }

        lock.lock()
        cached[host] = found
        cachedAt[host] = Date()
        lock.unlock()
        return found
    }

    /// DoH 查询本身用最朴素的 URLSession（不带任何自定义头，避免 DoH 服务挑剔）
    private static func plainGet(_ urlStr: String) throws -> String {
        guard let url = URL(string: urlStr) else { throw CloudError.badUrl }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/dns-json", forHTTPHeaderField: "accept")
        var out: String?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, e in
            if let e = e { err = e }
            else { out = String(data: data ?? Data(), encoding: .utf8) }
            sem.signal()
        }.resume()
        sem.wait()
        if let e = err { throw e }
        return out ?? ""
    }

    /// DoH JSON 形如 {"Answer":[{"type":1,"data":"104.18.38.10"}, ...]}
    private static func parseAnswers(_ body: String) -> [String] {
        guard let d = body.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ans = j["Answer"] as? [[String: Any]] else { return [] }
        return ans.compactMap { a in
            guard (a["type"] as? Int) == 1 else { return nil }   // 只要 A 记录
            return a["data"] as? String
        }
    }
}

/// 极简 HTTP（全同步，调用方自行放后台线程）
enum Net {
    /// 在闭包间传递连接就绪标志（避免直接捕获 var 触发并发告警）
    private final class Flag {
        private let lk = NSLock()
        private var v = false
        func set() { lk.lock(); v = true; lk.unlock() }
        func get() -> Bool { lk.lock(); defer { lk.unlock() }; return v }
    }

    /// 收数据用的可变缓冲（receive 回调可能跨队列，必须加锁）
    private final class Buf {
        private let lk = NSLock()
        private var d = Data()
        func add(_ x: Data) { lk.lock(); d.append(x); lk.unlock() }
        func all() -> Data { lk.lock(); defer { lk.unlock() }; return d }
    }

    static func get(_ url: String, _ headers: [String: String]) throws -> String {
        try request(url, "GET", headers, nil)
    }

    static func post(_ url: String, _ headers: [String: String], _ body: String) throws -> String {
        try request(url, "POST", headers, body)
    }

    /// 网络层抖动自动重试的次数。移动网络下连接被重置（URLError.networkConnectionLost）
    /// 太常见，一次就放弃会让用户看到「Supabase 失败：Connection reset」而以为云端坏了
    /// —— 其实再连一次就好。只重试网络层异常，服务器已回话的（4xx/5xx）不重试。
    private static let retryCount = 2

    private static func request(_ urlStr: String, _ method: String,
                                _ headers: [String: String], _ body: String?) throws -> String {
        var lastError: Error?
        for attempt in 0...retryCount {
            do {
                return try once(urlStr, method, headers, body)
            } catch let e as CloudError {
                throw e                          // 服务器答话了，重试无用
            } catch {
                /* 超时不要重试：每次要等满 20s，再试只是让用户干等。
                   注意 Swift 的 catch 模式里 where 子句引用不到刚绑定的变量，
                   只能在体内判（写成 `catch let e as URLError where e.code == ...` 编译不过）。 */
                if let u = error as? URLError, u.code == .timedOut { throw error }
                lastError = error
                if attempt < retryCount {
                    Thread.sleep(forTimeInterval: 0.4 * Double(attempt + 1))   // 0.4s / 0.8s
                }
            }
        }
        throw lastError ?? CloudError.badResponse
    }

    /* ============ 域名直连（绕开被污染的运营商 DNS） ============ */

    /// 这次请求要不要走「DoH 解析 + IP 直连」。
    /// 只对 Supabase 生效：腾讯云是国内域名，走系统 DNS 又快又稳，没必要多绕一圈。
    private static func pinHost(_ urlStr: String) -> String? {
        guard urlStr.contains("supabase.co") else { return nil }
        guard let u = URL(string: urlStr), let h = u.host else { return nil }
        return h
    }

    private static func once(_ urlStr: String, _ method: String,
                             _ headers: [String: String], _ body: String?) throws -> String {
        let host = pinHost(urlStr)
        /* ① 先按原样请求（走系统 DNS）。通就直接用 —— 大多数网络下这就是最快的路。
           对 Supabase 把这一步的超时压到 5 秒：反正常见失败模式就是「DNS 给的 IP 不可达」，
           与其让用户干等 20 秒再换路，不如早点切到 IP 直连。 */
        do {
            return try onceDirect(urlStr, method, headers, body, timeout: host == nil ? 20 : 5)
        } catch let e as CloudError {
            throw e                                    // 服务器答话了（4xx/5xx），换 IP 也无用
        } catch {
            guard let host = host else { throw error }
            /* 超时 / 连不上 / 连接被重置 → 极可能是 DNS 给的 IP 不可达，换我们自己解析的。
               其它错误（证书、地址非法）不折腾，直接抛。 */
            guard isConnFailure(error) else { throw error }

            /* ② DoH 解析 + 逐个 IP 直连。
               走 NWConnection 而不是 URLSession：URLSession 的 SNI 取决于 URL 的 host，
               换成 IP 后 SNI 就成了 IP，Cloudflare 会回一张不含该域名的证书，校验必然失败。
               NWConnection 让我们显式指定 SNI（仍用原域名），连的是 IP —— 两者各就各位。 */
            var last = error
            for ip in SbDns.ips(for: host) {
                do {
                    return try rawHttps(ip: ip, sni: host, urlStr: urlStr,
                                        method: method, headers: headers, body: body)
                } catch let e as CloudError {
                    throw e                            // 服务器答话了，别再换 IP 了
                } catch {
                    last = error
                }
            }
            throw last
        }
    }

    /// 网络层「连不上」类错误 —— 只有这类才值得换 IP 重来
    private static func isConnFailure(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        switch u.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func onceDirect(_ urlStr: String, _ method: String,
                                   _ headers: [String: String], _ body: String?,
                                   timeout: TimeInterval) throws -> String {
        guard let url = URL(string: urlStr) else { throw CloudError.badUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
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

    /* ============ 裸 HTTPS：连 IP，SNI 用域名 ============ */

    /// 自己用 NWConnection 发一次 HTTPS 请求。
    ///
    /// 为什么要「裸」写：URLSession 的 SNI 跟着 URL 的 host 走，host 换成 IP 后
    /// SNI 就成了 IP，Cloudflare 会返回一张不含 supabase.co 的证书 → 校验失败。
    /// NWConnection 允许【目标地址】和【SNI】分开指定：连 `104.18.38.10:443`，
    /// TLS 里报 `jcaobupbubldipbrzfuo.supabase.co`，于是证书校验正常通过，
    /// 而 DNS 被完全绕开 —— 这套系统 DNS 给出坏 IP 的场景的唯一解。
    private static func rawHttps(ip: String, sni: String, urlStr: String,
                                 method: String, headers: [String: String],
                                 body: String?) throws -> String {
        guard let u = URL(string: urlStr), let host = u.host else { throw CloudError.badUrl }
        var path = u.path.isEmpty ? "/" : u.path
        if let q = u.query { path += "?" + q }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(ip),
                                port: NWEndpoint.Port(rawValue: UInt16(u.port ?? 443))!, using: params)

        /* 连接状态用 Flag 在闭包间传递，避免直接捕获 var 造成并发告警 */
        let flag = Flag()
        let sem = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: flag.set(); sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        /* 直连这一步的总预算要短：本来就是在「系统 DNS 那条路已经失败了」之后才走的，
           再让用户等十几秒没有意义。8 秒连不上就判这个 IP 不行，换下一个。 */
        if sem.wait(timeout: .now() + 8) == .timedOut || !flag.get() {
            conn.cancel()
            throw URLError(.timedOut)
        }

        /* 组请求。Host 用域名（HTTP 层也是按域名路由），Content-Length 自己算。 */
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        head += "Accept: application/json\r\n"
        head += "Connection: close\r\n"
        var seenCT = false
        for (k, v) in headers {
            if k.lowercased() == "host" { continue }
            if k.lowercased() == "content-type" { seenCT = true }
            head += "\(k): \(v)\r\n"
        }
        var payload = Data()
        if let b = body {
            payload = Data(b.utf8)
            if !seenCT { head += "Content-Type: application/json; charset=utf-8\r\n" }
            head += "Content-Length: \(payload.count)\r\n"
        }
        head += "\r\n"

        var buf = Data(head.utf8)
        buf.append(payload)

        /* 收数据。recv 在闭包链里被反复 append，用 Buf（带锁）避免并发问题。 */
        let recv = Buf()
        let sem2 = DispatchSemaphore(value: 0)
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let d = data, !d.isEmpty { recv.add(d) }
                if done || err != nil { sem2.signal(); return }
                pump()
            }
        }
        conn.send(content: buf, completion: .contentProcessed { err in
            if err != nil { sem2.signal(); return }
            pump()
        })
        _ = sem2.wait(timeout: .now() + 10)
        conn.cancel()

        let raw = recv.all()
        guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw URLError(.badServerResponse)
        }
        let headerText = String(data: raw.subdata(in: 0..<headEnd.lowerBound), encoding: .utf8) ?? ""
        var bodyData = raw.subdata(in: headEnd.upperBound..<raw.count)
        /* Connection: close 时可能是 chunked；这里简单剥一层 chunked 编码 */
        if headerText.lowercased().contains("transfer-encoding: chunked") {
            bodyData = dechunk(bodyData) ?? bodyData
        }
        let text = String(data: bodyData, encoding: .utf8) ?? ""
        let first = headerText.split(separator: "\r\n").first.map(String.init) ?? ""
        guard let code = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw URLError(.badServerResponse)
        }
        if code >= 400 { throw CloudError.http(code, errorMessage(text)) }
        return text
    }

    /// 剥掉 HTTP/1.1 chunked 传输编码
    private static func dechunk(_ d: Data) -> Data? {
        var out = Data()
        var i = d.startIndex
        while i < d.endIndex {
            guard let nl = d[i...].range(of: Data("\r\n".utf8)) else { return out }
            let sizeStr = String(data: d[i..<nl.lowerBound], encoding: .utf8)?
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { return out }
            i = nl.upperBound
            if size == 0 { break }
            let end = d.index(i, offsetBy: size, limitedBy: d.endIndex) ?? d.endIndex
            out.append(d[i..<end])
            i = d.index(end, offsetBy: 2, limitedBy: d.endIndex) ?? d.endIndex
        }
        return out
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

    /// 两台时间戳的容差（秒）。**很有必要**：网页版一次「保存」是分两次写给腾讯云和
    /// Supabase 的，两次取当前时间会差几毫秒（实测生产环境相差 2ms）。
    /// 不设容差会把「同一时刻的同一份数据」误判成「一旧一新」——
    /// 界面上会出现「腾讯云落后」这种假警报，而且每次读取都会白白触发一次无意义补写。
    /// 1 秒足够覆盖这种抖动，又远小于任何真实的改动间隔。
    static let syncTol: TimeInterval = 1.0

    /// 两份数据算不算「同一版本」
    static func sameVersion(_ a: Date?, _ b: Date?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) <= syncTol
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

    /// Date → 与 nowIso() 同格式的 UTC 字符串（补写旧数据时沿用原来的时间戳）
    static func iso(from d: Date?) -> String {
        guard let d = d else { return nowIso() }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

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

    /// 带时间戳的读取：两台都读，比出谁最新。
    ///
    /// `fallbackToken`（v0.5.4 起）：匿名读失败且是认证类错误时，拿登录令牌再读一次。
    /// 读云端历来只带 apikey（匿名读），万一服务端收紧匿名读，明明登着也会读到空 ——
    /// 2026-10-10 事故就是这个形态（读不到 → 只剩内置快照 → 一保存就覆盖云端）。
    static func cbReadSnap(fallbackToken: String? = nil) throws -> Snap? {
        let url = cbBase + "/v1/rdb/rest/timetable_state?select=data,updated_at&id=eq.1"
        do {
            return try pickSnap(Net.get(url, cbHeaders(nil)), "cb")
        } catch {
            if let t = fallbackToken, !t.isEmpty, CloudError.isAuthFailure(error) {
                return try pickSnap(Net.get(url, cbHeaders(t)), "cb")
            }
            throw error
        }
    }

    static func sbReadSnap(fallbackToken: String? = nil) throws -> Snap? {
        let url = sbUrl + "/rest/v1/timetable_state?select=data,updated_at&id=eq.1"
        do {
            return try pickSnap(Net.get(url, sbHeaders(nil)), "sb")
        } catch {
            if let t = fallbackToken, !t.isEmpty, CloudError.isAuthFailure(error) {
                return try pickSnap(Net.get(url, sbHeaders(t)), "sb")
            }
            throw error
        }
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

    /// 用 refresh_token 换新的 access_token（腾讯云）。
    ///
    /// ⚠ 两个坑（与安卓端 `Cloud.cbRefresh` 保持一致，别再改回去）：
    ///   ① `grant_type` 必须放在【请求体】里；放 URL query 会 400
    ///      "grant type must be one of [authorization_code, refresh_token, ...]"。
    ///   ② 【不能带 Authorization 头】：带 apikey(anon key) → 401 "token hash not match"；
    ///      带已过期的 access_token → 400 failed_precondition "token expiry at ..."。
    ///      只带 apikey + x-ty-id 才是 200（2026-10-08 实测）。
    ///
    /// 之前 iOS 端【完全没有刷新逻辑】：access_token 两小时一过就静默失效，
    /// 界面还显示「已登录」，但写入腾讯云一律 401，改动只落到 Supabase；
    /// 而读取又是「两台都读、取最新的那份」，于是表现成「改了课表像没改」。
    static func cbRefresh(_ refreshToken: String) throws -> Auth {
        guard !refreshToken.isEmpty else { throw CloudError.badResponse }
        var h = cbHeaders(nil)
        h.removeValue(forKey: "Authorization")          // 关键：刷新时不能带
        let out = try Net.post(cbBase + "/auth/v1/token", h,
                               jsonBody(["grant_type": "refresh_token",
                                         "refresh_token": refreshToken]))
        guard let d = out.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw CloudError.badResponse
        }
        var a = Auth()
        a.token = j["access_token"] as? String ?? ""
        if a.token.isEmpty { throw CloudError.badResponse }
        // refresh_token 用一次就轮换，必须把新的存回去，否则下次刷新必失败
        a.refresh = j["refresh_token"] as? String ?? refreshToken
        a.uid = j["sub"] as? String ?? ""
        if a.uid.isEmpty { a.uid = uidFromJwt(a.token) }
        return a
    }

    /// 用 refresh_token 换新的 access_token（Supabase）。
    /// 走的是 GoTrue 标准形态：grant_type 放 URL query、Authorization 用 anon key —— 这条实测正常。
    /// （腾讯云那条恰好相反，见 cbRefresh 的注释，两者不要互相「统一」。）
    static func sbRefresh(_ refreshToken: String) throws -> Auth {
        guard !refreshToken.isEmpty else { throw CloudError.badResponse }
        let out = try Net.post(sbUrl + "/auth/v1/token?grant_type=refresh_token", sbHeaders(nil),
                               jsonBody(["refresh_token": refreshToken]))
        guard let d = out.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw CloudError.badResponse
        }
        var a = Auth()
        a.token = j["access_token"] as? String ?? ""
        if a.token.isEmpty { throw CloudError.badResponse }
        a.refresh = j["refresh_token"] as? String ?? refreshToken
        if let u = j["user"] as? [String: Any] {
            a.uid = u["id"] as? String ?? ""
        }
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
