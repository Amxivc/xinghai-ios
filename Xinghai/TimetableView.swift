import SwiftUI

struct TimetableView: View {
    @ObservedObject private var app = AppState.shared
    @State private var week = M.currentWeek
    @State private var personIdx = 0

    private var person: Person? {
        app.persons.indices.contains(personIdx) ? app.persons[personIdx] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let b = app.banner {
                BannerView(text: b)
            }
            header
            Divider()
            if app.persons.isEmpty {
                Spacer()
                if app.loading {
                    ProgressView("同步云端数据…")
                } else {
                    Text("暂无数据").foregroundColor(.secondary)
                }
                Spacer()
            } else {
                weekGrid
            }
        }
        .task { if app.persons.isEmpty { app.load() } }
    }

    /* ================= 顶部导航 ================= */

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if week > 1 { week -= 1 }
            } label: {
                Image(systemName: "chevron.left").font(.body)
            }
            .buttonStyle(.borderless)

            VStack(spacing: 2) {
                Text("第 \(week) 周").font(.headline)
                Text("\(M.weekDate(week, 1)) ~ \(M.weekDate(week, 7))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .frame(minWidth: 110)
            .padding(.vertical, 4)
            .liquidGlass(cornerRadius: 14)

            Button {
                if week < M.TOTAL_WEEKS { week += 1 }
            } label: {
                Image(systemName: "chevron.right").font(.body)
            }
            .buttonStyle(.borderless)

            Button("今天") { week = M.currentWeek }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .buttonStyle(.plain)

            Spacer()

            Menu {
                ForEach(Array(app.persons.enumerated()), id: \.offset) { i, p in
                    Button {
                        personIdx = i
                    } label: {
                        if i == personIdx {
                            Label(p.name.isEmpty ? "（未命名）" : p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name.isEmpty ? "（未命名）" : p.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(person?.name ?? "选择成员").lineLimit(1)
                    Image(systemName: "chevron.down")
                }
                .font(.subheadline)
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /* ================= 周网格 ================= */

    private var weekGrid: some View {
        GeometryReader { geo in
            let axisW: CGFloat = 34
            let gap: CGFloat = 2
            let rowH: CGFloat = 56
            let colW = max(36, (geo.size.width - axisW - gap * 8 - 12) / 7)
            ScrollView {
                HStack(alignment: .top, spacing: gap) {
                    // 左侧时间轴
                    VStack(spacing: gap) {
                        Text("").frame(height: 18)
                        ForEach(1...M.periods.count, id: \.self) { p in
                            VStack(spacing: 0) {
                                Text("\(p)")
                                    .font(.system(size: 10, weight: .medium))
                                Text(M.periods[p - 1][1])
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: axisW, height: rowH)
                        }
                    }
                    ForEach(1...7, id: \.self) { day in
                        dayColumn(day, colW: colW, rowH: rowH, gap: gap)
                    }
                }
                .padding(6)
            }
        }
    }

    private func dayColumn(_ day: Int, colW: CGFloat, rowH: CGFloat, gap: CGFloat) -> some View {
        let stride = rowH + gap
        let list = person?.courses.filter { $0.d == day && $0.inWeek(week) } ?? []
        let isToday = (day == M.todayDay && week == M.currentWeek)
        return VStack(spacing: gap) {
            Text(M.days[day - 1])
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundColor(isToday ? .blue : .secondary)
                .frame(width: colW, height: 18)
            ZStack(alignment: .topLeading) {
                VStack(spacing: gap) {
                    ForEach(1...M.periods.count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(UIColor.systemGroupedBackground))
                            .frame(width: colW, height: rowH)
                    }
                }
                ForEach(list.indices, id: \.self) { i in
                    let c = list[i]
                    courseBlock(c)
                        .frame(width: colW,
                               height: rowH * CGFloat(c.span) + gap * CGFloat(c.span - 1),
                               alignment: .topLeading)
                        .offset(y: stride * CGFloat(c.s - 1))
                }
            }
        }
    }

    private func courseBlock(_ c: Course) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.n)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(3)
                .minimumScaleFactor(0.55)
            if !c.r.isEmpty {
                Text(c.r)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(.secondary)
            }
            if !c.t.isEmpty {
                Text(c.t)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.color.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.color.opacity(0.55), lineWidth: 0.8))
    }
}
