import SwiftUI
import Charts

struct RecordChartView: View {
    let series: RecordSeries
    let presentation: RecordPresentation
    @Binding var selectedDate: String?

    private var months: [String] { Array(Set(series.days.map { String($0.date.prefix(7)) })).sorted() }
    private var lookup: [String: RecordDay] { Dictionary(uniqueKeysWithValues: series.days.map { ($0.date, $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if presentation == .bar {
                bars
            } else {
                ForEach(months, id: \.self) { month in monthGrid(month) }
                HStack(spacing: 5) {
                    Text("无记录").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0...4, id: \.self) { level in
                        Rectangle().fill(color(level)).frame(width: 12, height: 12)
                    }
                    Text("多").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("按本次范围分级").font(.caption2).foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("颜色越深，当天记录的数量越多；灰色表示无记录")
            }
            HStack {
                Text(RecordStatistics.amount(series.total, kind: series.activity)).font(.headline)
                Spacer()
                Text("\(series.recordedDays) 天有记录").font(.subheadline).foregroundStyle(.secondary)
            }
            if series.hasPending { Text("包含待同步记录").font(.caption).foregroundStyle(.orange) }
            if let selectedDate, let day = lookup[selectedDate] {
                Text("\(selectedDate) · \(day.count == 0 ? "无记录" : RecordStatistics.amount(day.amount, kind: series.activity))\(day.pending ? " · 含待同步" : "")")
                    .font(.subheadline).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var bars: some View {
        Chart(series.days) { day in
            if day.count > 0 {
                BarMark(x: .value("日期", day.date), y: .value(series.activity.unitLabel, day.amount))
                    .foregroundStyle(day.pending ? Color.orange : Color.accentColor)
                    .accessibilityLabel(day.date)
                    .accessibilityValue(RecordStatistics.amount(day.amount, kind: series.activity) + (day.pending ? "，包含待同步" : ""))
            } else {
                PointMark(x: .value("日期", day.date), y: .value(series.activity.unitLabel, 0))
                    .symbolSize(8).foregroundStyle(Color.secondary.opacity(0.35))
                    .accessibilityLabel(day.date).accessibilityValue("无记录")
            }
            if selectedDate == day.date {
                RuleMark(x: .value("选中日期", day.date)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: 0...max(1, series.maximum * 1.1))
        .chartXAxis {
            AxisMarks(values: series.days.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.date }) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let index = series.days.firstIndex(where: { $0.date == key }), index % 3 == 0 { Text(String(key.suffix(2))).font(.caption2) }
                }
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: min(14, max(1, series.days.count)))
        .chartXSelection(value: $selectedDate)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in proxy.selectXValue(at: value.location.x) }
        }
        .frame(height: 200)
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.1) : Color.accentColor.opacity([0.0, 0.22, 0.42, 0.68, 1.0][level])
    }

    private func monthGrid(_ month: String) -> some View {
        let start = RecordDate.date(month + "-01")!
        let count = RecordDate.calendar.range(of: .day, in: .month, for: start)!.count
        let leading = (RecordDate.calendar.component(.weekday, from: start) + 5) % 7
        return VStack(alignment: .leading, spacing: 8) {
            Text(month.replacingOccurrences(of: "-", with: " / ")).font(.subheadline.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5), count: 7), spacing: 5) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                ForEach(0..<(leading + count), id: \.self) { index in
                    if index < leading {
                        Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                    } else {
                        let number = index - leading + 1
                        let key = month + String(format: "-%02d", number)
                        let day = lookup[key]
                        Button { selectedDate = key } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(day.map { color(series.level($0)) } ?? .clear)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    Text("\(number)").font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                                        .foregroundStyle((day.map { series.level($0) } ?? 0) >= 3 ? Color.white : Color.primary)
                                }
                                .overlay {
                                    if selectedDate == key { RoundedRectangle(cornerRadius: 5).stroke(Color.primary, lineWidth: 2) }
                                }
                                .overlay(alignment: .bottom) {
                                    if day?.pending == true { Circle().fill(.orange).frame(width: 4, height: 4).padding(.bottom, 2) }
                                }
                                .opacity(day == nil ? 0.2 : 1)
                        }.buttonStyle(.plain).disabled(day == nil)
                            .accessibilityLabel(key)
                            .accessibilityValue(day.map { $0.count == 0 ? "无记录" : RecordStatistics.amount($0.amount, kind: series.activity) + ($0.pending ? "，包含待同步" : "") } ?? "不在查询范围")
                            .accessibilityHint("查看当天明细")
                    }
                }
            }
        }
    }
}

struct RecordDetailRows: View {
    let rows: [RecordRow]
    let select: (RecordRow) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty { Text("当天没有记录").foregroundStyle(.secondary).padding() }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RecordKindIcon(kind: row.kind)
                        Text(row.kind.title)
                        Spacer()
                        Text(RecordStatistics.amount(row.amount, kind: row.kind)).fontWeight(.medium)
                    }
                    Text(row.performedOn + " · " + row.status).font(.caption).foregroundStyle(.secondary)
                    Button("在对话中处理") { select(row) }.font(.subheadline)
                }.padding(.vertical, 12)
                if row.id != rows.last?.id { Divider() }
            }
        }
    }
}
