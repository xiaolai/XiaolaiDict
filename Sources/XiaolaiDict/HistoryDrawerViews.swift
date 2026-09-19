import AppKit
import XiaolaiDictCore
import SwiftUI

/// Lays cards out as a Notification Center style pile that fans into a list.
///
/// `progress` is the layout's `animatableData`, so SwiftUI interpolates the geometry itself. That
/// is why this is a `Layout` rather than a stack of `.offset` modifiers: `placeSubviews` is handed
/// the real measured height of every card, so the fanned positions are exact without a
/// `GeometryReader` round-trip. The arithmetic lives in `CardPile`, where it can be tested.
struct CardStackLayout: Layout {
    var progress: Double
    var pile = CardPile()

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: pile.height(of: measure(subviews, width: width), progress: progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = measure(subviews, width: bounds.width)
        for index in subviews.indices {
            guard let placed = pile.placement(
                of: index, in: heights, width: bounds.width, progress: progress) else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placed.origin.x, y: bounds.minY + placed.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placed.size.width, height: placed.size.height))
        }
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
}

/// The panel's content. The window is already at its final docked rect; only this moves.
struct HistoryDrawerRootView: View {
    @Bindable var model: HistoryDrawerModel

    var body: some View {
        // No geometry yet means the drawer has not been laid out for a display. Drawing nothing is
        // right: a guessed size would be a window the reader can see and cannot explain.
        if let geometry = model.geometry {
            let offset = model.revealed ? CGSize.zero : geometry.hiddenOffset
            ZStack(alignment: .topLeading) {
                HistoryDrawerSurface(model: model, geometry: geometry)
                    .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
                    .offset(
                        x: geometry.contentOrigin.x + offset.width,
                        y: geometry.contentOrigin.y + offset.height)
                    .opacity(model.revealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: model.revealed)
            }
            .frame(
                width: geometry.windowRect.width, height: geometry.windowRect.height,
                alignment: .topLeading)
            .clipped()
            .ignoresSafeArea()
        }
    }
}

struct HistoryDrawerSurface: View {
    @Bindable var model: HistoryDrawerModel
    let geometry: DrawerGeometry

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            contents
        }
        .background(DrawerBackdrop())
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 26)
    }

    /// The corners touching the screen edge stay square, the way system panels do. Which pair that
    /// is comes from the geometry, so the view does not re-derive it from the edge.
    private var shape: UnevenRoundedRectangle {
        let r = geometry.cornerRadius
        switch geometry.squareCorners {
        case .none:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r,
                bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .trailing:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .leading:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .top:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: r,
                bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        case .bottom:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: r, style: .continuous)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
            Text("Read recently")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else if model.totalEntries > 0 {
                Text("^[\(model.totalEntries) word](inflect: true) · ^[\(model.days.count) day](inflect: true)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var contents: some View {
        if let problem = model.problem {
            notice(
                icon: "exclamationmark.triangle", title: "Your reading history is unavailable",
                detail: problem)
        } else if model.days.isEmpty && !model.isLoading {
            notice(
                icon: "book.closed", title: "Nothing read yet",
                detail: "Words you look up appear here, grouped by the day you met them.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.days) { day in
                        if day.isPiled {
                            DayPileView(
                                day: day,
                                expanded: Binding(
                                    get: { model.isExpanded(day) },
                                    set: { model.setExpanded($0, for: day) }))
                        } else {
                            TodayView(day: day)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DrawerBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }
}

/// Today is never piled — it is the part the reader came to read.
struct TodayView: View {
    let day: ReadingDay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            DayHeader(day: day, count: day.entries.count, isToday: true)
            VStack(spacing: 8) {
                ForEach(day.entries) { ReadingCardView(entry: $0) }
            }
        }
    }
}

/// An earlier day: a header and a pile of that day's cards, fanning open on a click.
struct DayPileView: View {
    let day: ReadingDay
    @Binding var expanded: Bool

    /// Piled, only the cards that show are built. Rendering fifty views to display three would cost
    /// fifty measurements in `placeSubviews` for nothing visible.
    private var rendered: [ReadingEntry] {
        expanded ? day.entries : Array(day.entries.prefix(CardPile().maxVisibleDepth + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: toggle) {
                DayHeader(
                    day: day, count: day.entries.count, isToday: false,
                    trailing: expanded ? "Show Less" : "Show All")
            }
            .buttonStyle(.plain)

            CardStackLayout(progress: expanded ? 1 : 0) {
                // Reversed so the deepest card is drawn first and the newest sits on top.
                ForEach(Array(rendered.enumerated()).reversed(), id: \.element.id) { position, entry in
                    ReadingCardView(entry: entry, contentOpacity: (expanded || position == 0) ? 1 : 0)
                        .transition(.opacity)
                }
            }
            // Piled, the whole pile is one target. Fanned out, clicks belong to the cards.
            .overlay {
                if !expanded {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { expanded.toggle() }
    }
}

private struct DayHeader: View {
    let day: ReadingDay
    let count: Int
    let isToday: Bool
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(
                    isToday ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08)))
                .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    /// The label is a classification; rendering it is the view's job, in the reader's own locale.
    private var title: String {
        switch day.label {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .weekday: return day.date.formatted(.dateTime.weekday(.wide))
        case .date: return day.date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// One lookup.
///
/// The word and **the reader's own sentence** — never a definition. A review surface that answers
/// the question destroys the retrieval that makes reviewing worth anything, which is the same rule
/// that keeps a gloss off `PriorEncounter`. `ReadingEntry` has nowhere to put one, so this is
/// enforced by the type rather than by the view remembering.
struct ReadingCardView: View {
    let entry: ReadingEntry
    /// 0 renders a blank plate. Buried cards show no content, the way Notification Center does it:
    /// it stops text reading through from behind, and a fifty-card pile only ever draws one card.
    var contentOpacity: Double = 1
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(entry.result == .found ? Color.accentColor : Color.secondary)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.lemma)
                        .font(.system(size: 12.5, weight: .semibold))
                    if entry.result != .found {
                        // A miss is recorded on purpose, and shown as one. It is usually a typo or
                        // a stray selection, and telling that from a real gap is the point.
                        Text("not found")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.sentence.isEmpty {
                    Text(sentence)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let where_ = place {
                    Text(where_)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .opacity(contentOpacity)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(.regularMaterial))
        .background(shape.fill(Color.primary.opacity(hovering ? 0.10 : 0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The sentence with the word the reader looked up picked out, so the card reads as the cue it
    /// is rather than as a line of prose.
    private var sentence: AttributedString {
        var text = AttributedString(entry.sentence)
        guard let range = entry.sentenceRange,
              let swiftRange = Range(range, in: entry.sentence),
              let marked = Range(swiftRange, in: text)
        else { return text }
        text[marked].font = .system(size: 11, weight: .semibold)
        text[marked].foregroundColor = .primary
        return text
    }

    /// Where it was read, as precisely as the ledger knows — the page or document title where there
    /// is one, otherwise the app.
    private var place: String? {
        if let label = entry.place.label { return label }
        return entry.place.name
    }
}
