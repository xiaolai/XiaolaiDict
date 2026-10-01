import SwiftUI

public enum LookupKeepStatus: Equatable, Sendable {
    case keeping, kept, needsMeaning, needsConfirmation, manual, failed, discarded, discardedExternally
}
public enum LookupKeepAction: Sendable { case retry, discard, undo }
private struct KeepStatusKey: EnvironmentKey { static let defaultValue: LookupKeepStatus? = nil }
private struct KeepActionKey: EnvironmentKey { static let defaultValue: @MainActor (LookupKeepAction) -> Void = { _ in } }
public extension EnvironmentValues {
    var lookupKeepStatus: LookupKeepStatus? { get { self[KeepStatusKey.self] } set { self[KeepStatusKey.self] = newValue } }
    var lookupKeepAction: @MainActor (LookupKeepAction) -> Void { get { self[KeepActionKey.self] } set { self[KeepActionKey.self] = newValue } }
}
public struct LookupKeepStatusViewBridge: View {
    @Environment(\.scale) private var scale
    @Environment(\.lookupKeepStatus) private var status
    @Environment(\.lookupKeepAction) private var action
    public init() {}
    public var body: some View {
        if let status {
            HStack(spacing: scale.space.inline) {
                switch status {
                case .keeping: Text("Keeping…")
                case .kept: Text("Kept for learning")
                case .needsMeaning: Text("Kept · Choose a meaning")
                case .needsConfirmation: Text("Kept · Confirm this meaning in Library")
                case .manual: Text("History kept · Choose Keep for learning to study")
                case .failed:
                    Text("Could not keep this lookup")
                    Button("Retry") { action(.retry) }
                case .discardedExternally:
                    Text("Discarded")
                    Button("Restore") { action(.undo) }
                case .discarded:
                    Text("Discarded")
                    Button("Undo") { action(.undo) }
                }
                Spacer(minLength: 0)
                if status != .discarded && status != .discardedExternally { Button("Discard") { action(.discard) } }
            }
            .font(.system(size: scale.text.micro))
            .foregroundStyle(.secondary)
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.tight)
        }
    }
}
