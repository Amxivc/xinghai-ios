import SwiftUI

struct MineView: View {
    @ObservedObject private var app = AppState.shared
    @State private var showLogin = false
    @State private var showLogoutConfirm = false
    @State private var showHistory = false

    var body: some View {
        NavigationView {
            List {
                accountSection
                cloudSection
                aboutSection
            }
            .navigationTitle("我的")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .sheet(isPresented: $showLogin) { LoginSheet() }
        .alert("退出登录？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { app.logout() }
        } message: {
            Text("退出后将无法保存修改到云端")
        }
        .onAppear {
            /* 进「我的」页 = 用户想看状态了。顺手体检一次（内部有 60 秒节流），
               掉线的话当场自动重连，状态行也会立刻变成「已自动重连」。 */
            app.checkSessions()
        }
    }

    /* ================= 账号卡 ================= */

    private var accountSection: some View {
        Section("账号") {
            if app.isLoggedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.cbUser ?? app.sbUser ?? "")
                            .font(.body.weight(.medium))
                        HStack(spacing: 6) {
                            Text(app.loginLabel)
                            Text(app.isAdmin ? "管理员" : "普通成员")
                                .foregroundColor(app.isAdmin ? .orange : .secondary)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        /* 只登录一台时把风险说出来。方向由 AppState 判断：
                           读数据不需要登录，未登录那台如果反而更新，危险是「改动会被覆盖」。 */
                        if let w = app.halfLoginWarning {
                            Text(w)
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                Button("退出登录", role: .destructive) { showLogoutConfirm = true }
            } else {
                Button {
                    showLogin = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("未登录").font(.body)
                            /* 同步中也要说清楚「能不能登录」，否则用户点了没反应会以为坏了。
                               登录本身是本地动作，和同步并不冲突。 */
                            Text(app.loading
                                 ? "正在同步（\(app.syncElapsed)s），仍可正常登录"
                                 : "登录后可修改课表与工作安排")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /* ================= 云端状态卡 ================= */

    private var cloudSection: some View {
        Section("云端状态") {
            InfoRow(label: "数据来源", value: app.sourceLabel)
            InfoRow(label: "成员数", value: app.persons.isEmpty ? "—" : "\(app.persons.count) 人")
            InfoRow(label: "课程总数", value: app.persons.isEmpty ? "—" : "\(app.totalCourses) 门")
            InfoRow(label: "更新时间", value: app.dataUpdatedAt.isEmpty ? "—" : app.dataUpdatedAt)
            /* 数据版本号：每次保存 +1，回滚不回退。报问题时说的就是它。 */
            InfoRow(label: "数据版本",
                    value: app.curVer > 0 ? "v\(app.curVer)" : "首次保存后开始编号")

            /* 两台服务器各自的状态：只同步上一台这件事，得让用户看得见 */
            HStack {
                Text("腾讯云").font(.subheadline)
                Spacer()
                Text(serverState(cb: true))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Supabase").font(.subheadline)
                Spacer()
                Text(serverState(cb: false))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if !app.cloudNote.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(app.cloudNote)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            /* 还有没写上的那台 —— Supabase 连不上时全靠这条说明「改动没丢、正在补」 */
            if !app.pendingTargets.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.blue)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待补写：" + app.pendingTargets
                                .map { $0 == "cb" ? "腾讯云" : "Supabase" }
                                .joined(separator: " / "))
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(app.pendingNote.isEmpty
                             ? "正在后台静默重试，成功后自动写入"
                             : app.pendingNote + "；会自动重试")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button {
                app.load(manual: true)
            } label: {
                HStack(spacing: 8) {
                    if app.loading { ProgressView().scaleEffect(0.85) }
                    Text(app.loading ? "同步中… \(app.syncElapsed)s" : "立即同步")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .liquidGlass(cornerRadius: 12)
            .buttonStyle(.plain)
            /* 不置灰：同步中再点也应给出一句「正在同步，请稍候」，
               置灰后点下去毫无反应，用户只会以为界面卡死了。 */
            .opacity(app.loading ? 0.6 : 1)

            /* 历史版本：每次保存都留一版，误删 / 被覆盖时能退回去（v0.5.6 起） */
            Button {
                showHistory = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                    Text("历史版本")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .liquidGlass(cornerRadius: 12)
            .buttonStyle(.plain)

            if app.loading {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        Text(app.syncStage.isEmpty ? "正在同步…" : app.syncStage)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)

                    /* 超过 8 秒补一句解释：让用户知道是网络慢，不是死机 */
                    if app.syncElapsed >= 8 {
                        Text(app.syncElapsed >= 20
                             ? "境外服务器这条线路较慢，正在换线路重试；腾讯云的数据已经就绪"
                             : "网络较慢，仍在尝试…")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 单台服务器的同步状态：未登录 / 取不到 / 最新 / 落后（带时间）
    /// 单台服务器：数据新旧 + 能不能写（登录）分开说。
    /// 读数据不需要登录，所以未登录的那台完全可能是较新的那份 —— 必须标出来。
    /// 另外把「登录态自检」的结论也标出来：用户反馈过「有时候随机掉其中一个」，
    /// 要让他看得出「正在自动重连（等着就行）」还是「凭证过期（得手动重登）」。
    private func serverState(cb: Bool) -> String {
        let logged = cb ? app.isCbLogged : app.isSbLogged
        let got = cb ? app.cbGot : app.sbGot
        let at = cb ? app.cbAt : app.sbAt

        /* 自检结论优先：比「取不到」信息量大得多 */
        let needLogin = cb ? app.cbNeedLogin : app.sbNeedLogin
        let offline = cb ? app.cbOffline : app.sbOffline
        let recovered = cb ? app.cbRecovered : app.sbRecovered
        if needLogin && !logged {
            return "登录已失效，需重新登录"
        }
        if offline && !got {
            return "已断开，正在后台自动重连…"
        }
        if recovered && got, let at = at {
            return "已自动重连（" + app.clockText(at) + "）"
        }

        if !got {
            /* 取不到时把原因一并说出来：以前只显示「取不到」，看不出是断网、
               超时、连接被重置还是 401，用户和我们都没法定位。 */
            let why = cb ? app.cbErr : app.sbErr
            let base = logged ? "取不到" : "未登录，也取不到"
            return why.isEmpty ? base : base + "：" + why
        }
        guard let at = at else { return logged ? "已连接" : "未登录" }
        /* 带容差判「最新」：网页版一次保存分两次写，两台会差几毫秒，
           不加容差会出现「同一分钟里一台最新一台落后」的假警报。 */
        let newest = max(app.cbAt ?? .distantPast, app.sbAt ?? .distantPast)
        var tag = at.addingTimeInterval(Cloud.syncTol) >= newest ? "最新" : "落后"
        if !logged { tag = "未登录 · " + tag }
        return tag + "（" + app.clockText(at) + "）"
    }

    /* ================= 关于卡 ================= */

    private var aboutSection: some View {
        Section("关于") {
            InfoRow(label: "应用", value: "星海音教宣传部")
            InfoRow(label: "版本", value: "iOS 客户端 v0.5.7（完整功能）")
            InfoRow(label: "单位", value: "星海音乐学院音乐教育学院")
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

/* ================= 登录弹窗 ================= */

struct LoginSheet: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 2
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var remember = AppState.shared.remember
    @State private var msg: String? = nil

    var body: some View {
        NavigationView {
            Form {
                Picker("登录到", selection: $mode) {
                    Text("腾讯云").tag(0)
                    Text("Supabase").tag(1)
                    Text("双端同时").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("邮箱（如 xxxxx@xx.com）", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("密码", text: $password)
                    Toggle("保持登录状态（下次打开免登录）", isOn: $remember)
                        .font(.subheadline)
                } footer: {
                    Text("腾讯云会自动取邮箱 @ 前面的部分作登录名。")
                }

                if let m = msg {
                    Section {
                        Text(m).font(.footnote).foregroundColor(.secondary)
                    }
                }

                if app.loading {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("云端正在同步（\(app.syncElapsed)s）。可以照常登录，登录成功后会自动重新同步一次。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section {
                    Button {
                        doLogin()
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(busy ? "登录中…" : "登  录")
                                .font(.body.weight(.medium))
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .liquidGlass(cornerRadius: 14)
                    .buttonStyle(.plain)
                    /* 只锁「登录中」。以前还锁了「邮箱或密码为空」，按钮点下去毫无反应，
                       用户根本不知道缺什么 —— 现在让他点，缺什么就直说。 */
                    .disabled(busy)
                }
            }
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func doLogin() {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        /* 以前是按钮直接置灰 —— 点了没动静，用户不知道是缺邮箱还是缺密码 */
        guard !e.isEmpty, !password.isEmpty else {
            msg = e.isEmpty ? "请先填邮箱（格式如 xxxxx@xx.com）" : "请先填密码"
            return
        }
        busy = true
        msg = app.loading ? "登录中…（云端正在同步，可能稍慢）" : nil
        app.login(email: e, password: password, mode: mode, remember: remember) { result in
            busy = false
            msg = result
            if app.isLoggedIn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
        }
    }
}
