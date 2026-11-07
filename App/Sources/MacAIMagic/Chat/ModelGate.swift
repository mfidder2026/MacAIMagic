import Foundation

/// The model writes one answer at a time (the engine runs with one slot). Conversations take turns here, first come
/// first served, and only while the model writes: a conversation that waits for the user's approval, or runs a
/// command, leaves the model to the others.
@MainActor
final class ModelGate: ObservableObject {
    /// The conversation the model is writing for now.
    @Published private(set) var holder: UUID?
    /// The conversations waiting their turn, in order.
    @Published private(set) var waiting: [UUID] = []
    private var queue: [(ticket: UUID, owner: UUID, go: CheckedContinuation<Bool, Never>)] = []

    /// Waits for the model. True: it is yours, call `release` when the answer is written. False: the task was
    /// cancelled while waiting.
    func acquire(_ owner: UUID) async -> Bool {
        if Task.isCancelled { return false }
        if holder == nil {
            holder = owner
            return true
        }
        let ticket = UUID()
        let got = await withTaskCancellationHandler {
            await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                queue.append((ticket, owner, go))
                waiting = queue.map(\.owner)
            }
        } onCancel: {
            Task { @MainActor in self.leave(ticket) }
        }
        return got
    }

    func release() {
        if queue.isEmpty {
            holder = nil
        } else {
            let next = queue.removeFirst()
            waiting = queue.map(\.owner)
            holder = next.owner
            next.go.resume(returning: true)
        }
    }

    /// A cancelled wait leaves the queue (if it was still in it).
    private func leave(_ ticket: UUID) {
        guard let i = queue.firstIndex(where: { $0.ticket == ticket }) else { return }
        let gone = queue.remove(at: i)
        waiting = queue.map(\.owner)
        gone.go.resume(returning: false)
    }
}
