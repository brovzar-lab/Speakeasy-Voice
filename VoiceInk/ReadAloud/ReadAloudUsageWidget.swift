import SwiftUI

/// Compact usage / spend widget rendered in the sidebar (and optionally as a
/// full-width section in the Read Aloud settings view via `.expanded`).
///
/// Reads its data from `ReadAloudUsageTracker.shared`. Two visual variants:
///
/// - `.compact` — sidebar tile: month total, budget bar, today subline.
///   Clickable to jump to the Read Aloud settings screen.
/// - `.expanded` — the previous in-settings view with per-provider bars,
///   recent reads log, budget editor, reset button.
struct ReadAloudUsageWidget: View {
    enum Style {
        case compact
        case expanded
    }

    let style: Style
    /// Called when the widget is tapped in `.compact` mode. Usually navigates
    /// the main window to the Read Aloud settings section.
    var onTap: (() -> Void)?

    @ObservedObject private var usage = ReadAloudUsageTracker.shared

    @State private var showResetAlert = false
    @State private var showRecentReads = false
    @State private var budgetInput: String = ""

    var body: some View {
        switch style {
        case .compact: compactBody
        case .expanded: expandedBody
        }
    }

    // MARK: - Compact (sidebar)

    private var compactBody: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(headerAccent)
                    Text("READ ALOUD SPEND")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                    Spacer(minLength: 0)
                    if usage.isOverBudget {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(currency(usage.costThisMonth))
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .foregroundStyle(spendColor)
                    Text("this month")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let progress = usage.budgetProgress {
                    compactBudgetBar(progress: progress)
                }

                HStack(spacing: 6) {
                    subMetric(label: "Today", value: currency(usage.costToday))
                    Divider().frame(height: 10)
                    subMetric(label: "Week", value: currency(usage.costThisWeek))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("View Read Aloud usage & budget")
    }

    private func compactBudgetBar(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(budgetBarColor(progress: progress))
                        .frame(width: max(3, geo.size.width * CGFloat(min(1.0, progress))))
                }
            }
            .frame(height: 5)

            HStack {
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(budgetBarColor(progress: progress))
                Spacer(minLength: 0)
                Text("of \(currency(usage.monthlyBudgetUSD))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subMetric(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private var spendColor: Color {
        if usage.isOverBudget { return .red }
        if let p = usage.budgetProgress, p >= 0.8 { return .orange }
        return .primary
    }

    private var headerAccent: Color {
        if usage.isOverBudget { return .red }
        return Color.accentColor
    }

    private var borderColor: Color {
        if usage.isOverBudget { return .red.opacity(0.4) }
        return Color.primary.opacity(0.1)
    }

    // MARK: - Expanded (settings view)

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            costTotalsGrid

            let byProvider = usage.breakdownByProvider(since: usage.startOfThisMonth)
            if !byProvider.isEmpty {
                providerBreakdownView(byProvider)
            }

            budgetRow

            if let projected = usage.projectedMonthlyCost {
                LabeledContent("Projected This Month") {
                    Text(currency(projected))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(projected > usage.monthlyBudgetUSD && usage.monthlyBudgetUSD > 0 ? .orange : .secondary)
                }
            }
        }
        .alert("Reset Usage History?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { usage.resetAll() }
        } message: {
            Text("This clears the recorded reads and spend totals shown here. It does not affect any real charges on your provider accounts.")
        }
    }

    private var costTotalsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                costCell(label: "Today", value: usage.costToday, reads: usage.readCount(since: usage.startOfToday))
                costCell(label: "This Week", value: usage.costThisWeek, reads: usage.readCount(since: usage.startOfThisWeek))
            }
            GridRow {
                costCell(label: "This Month", value: usage.costThisMonth, reads: usage.readCount(since: usage.startOfThisMonth), emphasized: true)
                costCell(label: "Lifetime", value: usage.lifetimeCost, reads: usage.records.count)
            }
        }
    }

    private func costCell(label: String, value: Double, reads: Int, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(currency(value))
                .font(.system(size: emphasized ? 20 : 16, weight: emphasized ? .bold : .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("\(reads) read\(reads == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerBreakdownView(_ rows: [ReadAloudUsageTracker.ProviderBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Provider (This Month)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            let total = rows.reduce(0.0) { $0 + $1.cost }
            ForEach(rows) { row in
                providerBreakdownRow(row: row, totalCost: total)
            }
        }
    }

    private func providerBreakdownRow(row: ReadAloudUsageTracker.ProviderBreakdown, totalCost: Double) -> some View {
        let fraction: Double = totalCost > 0 ? row.cost / totalCost : (row.reads > 0 ? 1.0 : 0)

        return HStack(spacing: 8) {
            Text(providerDisplayName(row.provider))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(providerColor(row.provider))
                        .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 10)

            Text(currency(row.cost))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var budgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monthly Budget")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                budgetField
            }

            if let progress = usage.budgetProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(budgetBarColor(progress: progress))
                            .frame(width: max(4, geo.size.width * CGFloat(min(1.0, progress))))
                    }
                }
                .frame(height: 8)
            }

            Toggle("Block paid cloud voices at this limit", isOn: $usage.hardLimitEnabled)
                .font(.system(size: 12, weight: .medium))

            Text(usage.monthlyBudgetUSD == 0
                 ? "The $0 limit blocks every paid cloud request. Local HD and Apple always remain available."
                 : "Speakeasy estimates each request before sending it and blocks any paid read that would cross this limit.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var budgetField: some View {
        HStack(spacing: 4) {
            Text("$")
                .foregroundStyle(.secondary)
            TextField("0", text: Binding(
                get: {
                    budgetInput.isEmpty && usage.monthlyBudgetUSD > 0
                        ? String(format: "%.2f", usage.monthlyBudgetUSD)
                        : budgetInput
                },
                set: { newValue in
                    budgetInput = newValue
                    if let v = Double(newValue.replacingOccurrences(of: ",", with: ".")) {
                        usage.monthlyBudgetUSD = max(0, v)
                    } else if newValue.isEmpty {
                        usage.monthlyBudgetUSD = 0
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Formatters shared across styles

    private func currency(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "local": return String(localized: "Local HD")
        case "apple": return String(localized: "Apple")
        case "elevenlabs": return String(localized: "ElevenLabs")
        case "openai": return String(localized: "OpenAI")
        case "gemini": return String(localized: "Gemini")
        default: return provider.capitalized
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "local": return Color(red: 0.55, green: 0.38, blue: 0.82)
        case "elevenlabs": return Color(red: 0.36, green: 0.58, blue: 0.85)
        case "openai": return Color(red: 0.30, green: 0.72, blue: 0.55)
        case "gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "apple": return Color.gray.opacity(0.6)
        default: return Color.accentColor
        }
    }

    private func budgetBarColor(progress: Double) -> Color {
        if progress >= 1.0 { return .red }
        if progress >= 0.8 { return .orange }
        if progress >= 0.5 { return .yellow }
        return .accentColor
    }
}
