# 星海音教宣传部 · iOS 客户端

星海音乐学院音乐教育学院宣传部工作网站的原生 iOS 版本（SwiftUI）。

## 结构

- `project.yml` — xcodegen 工程描述（云端构建时生成 Xinghai.xcodeproj）
- `Xinghai/` — Swift 源码
  - `Model.swift` — 数据模型 + 业务规则（周次/节次/日期换算，字段与安卓版逐一对齐）
  - `Cloud.swift` — 云端层：腾讯云 CloudBase（首选）+ Supabase（备用），纯 REST
  - `AppState.swift` — 全局状态、双端登录、本地缓存
  - `TimetableView.swift` — 课表周网格
  - `CalendarView.swift` — 工作台历月历 + 当日列表
  - `MineView.swift` — 账号 / 云端状态 / 关于
- `.github/workflows/build.yml` — GitHub Actions 云端构建（macOS runner → 未签名 IPA）

## 构建产物

每次 push 后 GitHub Actions 自动构建，在仓库 **Actions → 最新运行 → Artifacts**
下载 `Xinghai-unsigned-ipa`（未签名 IPA），用爱思助手 / Sideloadly 以自己的
Apple ID 签名后安装到 iPhone（免费证书 7 天有效期）。

## 云端

- 首选：腾讯云开发 CloudBase PostgreSQL（环境 `xh-yjxcb-d6g4mu0b64c1e26e5`）
- 备份：Supabase（项目 `jcaobupbubldipbrzfuo`）
- 表：`timetable_state`（id=1 单行全量数据）、`admins`（管理员白名单）
