import SwiftUI

struct MineView: View {
    @ObservedObject private var app = AppState.shared
    @State private var showLogin = false
    @State private var showLogoutConfirm = false

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
        .sheet(isPresented: $showLogin) { LoginSheet() }
        .alert("退出登录？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { app.logout() }
        } message: {
            Text("退出后将无法保存修改到云端")
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
                            Text("登录后可修改课表与工作安排")
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

            Button {
                app.load()
            } label: {
                HStack {
                    if app.loading { ProgressView().padding(.trailing, 6) }
                    Text(app.loading ? "同步中…" : "立即同步")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .liquidGlass(cornerRadius: 12)
            .buttonStyle(.plain)
            .disabled(app.loading)
        }
    }

    /// 单台服务器的同步状态：未登录 / 取不到 / 最新 / 落后（带时间）
    private func serverState(cb: Bool) -> String {
        let logged = cb ? app.isCbLogged : app.isSbLogged
        let got = cb ? app.cbGot : app.sbGot
        let at = cb ? app.cbAt : app.sbAt
        if !logged { return "未登录" }
        if !got { return "取不到" }
        guard let at = at else { return "已连接" }
        let newest = max(app.cbAt ?? .distantPast, app.sbAt ?? .distantPast)
        return (at >= newest ? "最新" : "落后") + "（" + app.clockText(at) + "）"
    }

    /* ================= 关于卡 ================= */

    private var aboutSection: some View {
        Section("关于") {
            InfoRow(label: "应用", value: "星海音教宣传部")
            InfoRow(label: "版本", value: "iOS 客户端 v0.4.2（完整功能）")
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
                    .disabled(busy || email.isEmpty || password.isEmpty)
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
        busy = true
        msg = nil
        app.login(email: email, password: password, mode: mode, remember: remember) { result in
            busy = false
            msg = result
            if app.isLoggedIn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
        }
    }
}
