import Foundation
import OfficeCore

@MainActor public final class ReminderCoordinator {
    private struct TaskFingerprint: Equatable {
        let time: Date
        let title: String
        let owner: String?
    }
    private let client: any NotificationClient
    private var generation = 0
    private var isRunning = false
    private var latest: ReminderPlan?
    private var knownRequests: [String: ReminderRequest] = [:]
    private var activeIDs: Set<String> = []
    private var latestFingerprints: [String: TaskFingerprint] = [:]
    private var knownFingerprints: [String: TaskFingerprint] = [:]
    public init(client: any NotificationClient) { self.client = client }

    public func reconcile(tasks: [TaskItem], preferences: AppPreferences, now: Date) async throws {
        generation += 1; latest = ReminderPlanner.plan(tasks: tasks, preferences: preferences, now: now)
        activeIDs = Set(tasks.filter { $0.status != .completed && ($0.dueAt != nil || $0.snoozedUntil != nil) }
            .map { "office.task.\($0.id.uuidString)" })
        if preferences.dailySummaryEnabled { activeIDs.insert("office.summary") }
        latestFingerprints = Dictionary(uniqueKeysWithValues: tasks.compactMap { item in
            guard item.status != .completed, let time = item.snoozedUntil ?? item.dueAt else { return nil }
            return ("office.task.\(item.id.uuidString)", TaskFingerprint(time: time, title: item.title, owner: item.owner))
        })
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while let plan = latest {
            let current = generation
            let fingerprints = latestFingerprints
            let auth = await client.authorization()
            let pending = await client.pendingIDs()
            let delivered = await client.deliveredIDs()
            if current != generation { continue }
            let desired = Set(plan.requests.map(\.id))
            let obsoletePending = pending.filter { $0.hasPrefix("office.") && !desired.contains($0) }
            let obsoleteDelivered = delivered.filter { id in
                guard id.hasPrefix("office.") else { return false }
                return !activeIDs.contains(id) || (knownFingerprints[id] != nil && knownFingerprints[id] != fingerprints[id])
            }
            client.remove(ids: Array(obsoletePending.union(obsoleteDelivered)))
            knownRequests = knownRequests.filter { activeIDs.contains($0.key) }
            guard auth == .authorized else {
                client.remove(ids: pending.filter { $0.hasPrefix("office.") }.map { $0 })
                return
            }
            for request in plan.requests {
                if current != generation { break }
                if knownRequests[request.id] == request && pending.contains(request.id) { continue }
                if let old = knownRequests[request.id], old != request { client.remove(ids: [request.id]) }
                do {
                    try await client.add(request)
                    knownRequests[request.id] = request
                } catch {
                    if current != generation { break }
                    throw error
                }
            }
            if current == generation { knownFingerprints = fingerprints; return }
        }
    }
}
