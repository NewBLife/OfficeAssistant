import Foundation
import Observation
import OfficeCore

@MainActor @Observable public final class TaskStore {
    public private(set) var items: [TaskItem] = []
    public var errorMessage: String?
    public private(set) var isLoaded = false
    @ObservationIgnored private let groups: GroupStore?
    @ObservationIgnored private let repository: any TaskRepository
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(repository: any TaskRepository, groups: GroupStore? = nil) {
        self.repository = repository; self.groups = groups
        do { try reload() } catch { errorMessage = error.localizedDescription }
    }
    public func reload() throws {
        do { items = try repository.load(); isLoaded = true; errorMessage = nil }
        catch { isLoaded = false; errorMessage = error.localizedDescription; throw error }
    }
    private func commit(_ snapshot: [TaskItem]) throws {
        guard isLoaded else { throw OfficeError.invalid("原有数据未能读取，已暂停保存，避免覆盖。请重试读取。") }
        do {
            let normalized = snapshot.map { value -> TaskItem in
                var value = value
                if let groups, groups.isLoaded { value.groupID = GroupRules.effectiveGroupID(value.groupID, groups: groups.groups) }
                return value
            }
            try repository.save(normalized); items = normalized; errorMessage = nil; onChange?()
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    public func upsert(_ item: TaskItem) throws {
        var item = item
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.owner?.isEmpty == true { item.owner = nil }
        try TaskRules.validate(item)
        if let previous = items.first(where: { $0.id == item.id }) {
            item.meetingLinks = previous.meetingLinks; item.meetingActionReceipts = previous.meetingActionReceipts
            guard previous.status != .completed, item.status != .completed else {
                throw OfficeError.invalid("请通过完成或撤销操作修改完成状态。")
            }
            item.snoozedUntil = previous.dueAt == item.dueAt ? previous.snoozedUntil : nil
        } else if item.status == .completed {
            throw OfficeError.invalid("请先保存任务，再标记完成。")
        }
        var snapshot = items.filter { $0.id != item.id }; snapshot.append(item)
        try commit(snapshot)
    }
    public func moveToGroup(id: UUID, groupID: UUID?) throws {
        guard let groups else { throw OfficeError.invalid("分组服务不可用。") }
        let target = try groups.normalized(groupID)
        guard groupID == nil || target != nil else { throw OfficeError.invalid("目标分组已删除。") }
        guard var item = items.first(where: { $0.id == id }) else { throw OfficeError.invalid("待办已不存在。") }
        item.groupID = target; try commit(items.map { $0.id == id ? item : $0 })
    }
    public func delete(id: UUID) throws { try commit(items.filter { $0.id != id }) }
    public func complete(id: UUID, at now: Date) throws {
        guard let item = items.first(where: { $0.id == id }), item.status != .completed else { return }
        let result = try TaskRules.complete(item, at: now)
        var snapshot = items.filter { $0.id != id }; snapshot.append(result.completed)
        if let next = result.next, !snapshot.contains(where: { $0.id == next.id }) { snapshot.append(next) }
        try commit(snapshot)
    }
    public func reopen(id: UUID) throws {
        guard var item = items.first(where: { $0.id == id }), item.status == .completed else { return }
        var snapshot = items
        if let nextID = item.nextOccurrenceID, let next = items.first(where: { $0.id == nextID }), let completedAt = item.completedAt {
            var original = item; original.status = .pending; original.completedAt = nil; original.nextOccurrenceID = nil
            var expected = try TaskRules.complete(original, at: completedAt).next
            expected?.id = nextID
            guard next == expected else { throw OfficeError.invalid("下一次任务已修改或处理，请先处理它，再撤销本次完成。") }
            snapshot.removeAll { $0.id == nextID }
        }
        item.status = .pending; item.completedAt = nil; item.nextOccurrenceID = nil
        snapshot.removeAll { $0.id == id }; snapshot.append(item)
        try commit(snapshot)
    }
    public func snooze(id: UUID, until: Date) throws {
        guard var item = items.first(where: { $0.id == id }), item.status != .completed else { return }
        item.snoozedUntil = until
        try commit(items.map { $0.id == id ? item : $0 })
    }
    public func linkMeeting(taskID: UUID, link: TaskMeetingLink) throws {
        guard var item = items.first(where: { $0.id == taskID }) else { throw OfficeError.invalid("这条待办已不存在。") }
        guard link.evidence.allSatisfy({ $0.segmentID.meetingID == link.meetingID }) else { throw OfficeError.invalid("来源会议不一致。") }
        var links = item.meetingLinks ?? []; links.removeAll { $0.id == link.id }; links.append(link); item.meetingLinks = links
        try commit(items.map { $0.id == taskID ? item : $0 })
    }
    public func unlinkMeeting(taskID: UUID, meetingID: UUID) throws {
        guard var item = items.first(where: { $0.id == taskID }) else { return }
        item.meetingLinks = (item.meetingLinks ?? []).filter { $0.meetingID != meetingID }
        try commit(items.map { $0.id == taskID ? item : $0 })
    }
    public func taskForCandidate(meetingID: UUID, candidateID: UUID) -> TaskItem? {
        items.first { ($0.meetingActionReceipts ?? []).contains { $0.meetingID == meetingID && $0.candidateID == candidateID } }
    }
    public func acceptMeetingAction(_ draft: TaskItem, candidateID: UUID, link: TaskMeetingLink, at: Date) throws -> TaskItem {
        guard link.candidateID == candidateID, link.evidence.allSatisfy({ $0.segmentID.meetingID == link.meetingID }) else { throw OfficeError.invalid("行动项来源不一致。") }
        if let existing = taskForCandidate(meetingID: link.meetingID, candidateID: candidateID) { return existing }
        guard !items.contains(where: { $0.id == candidateID }) else { throw OfficeError.invalid("事项标识冲突，未覆盖已有待办。") }
        var item = draft; item.id = candidateID; item.seriesID = candidateID; item.createdAt = at
        guard item.status != .completed else { throw OfficeError.invalid("新增待办不能直接标记为已完成。") }
        item.meetingLinks = [link]; item.meetingActionReceipts = [MeetingActionReceipt(meetingID: link.meetingID, candidateID: candidateID, joinedAt: at)]
        try TaskRules.validate(item); try commit(items + [item]); return item
    }
    public func associateMeetingAction(taskID: UUID, candidateID: UUID, link: TaskMeetingLink, at: Date) throws -> TaskItem {
        guard link.candidateID == candidateID, link.evidence.allSatisfy({ $0.segmentID.meetingID == link.meetingID }) else { throw OfficeError.invalid("行动项来源不一致。") }
        if let existing = taskForCandidate(meetingID: link.meetingID, candidateID: candidateID) { return existing }
        guard var item = items.first(where: { $0.id == taskID }) else { throw OfficeError.invalid("这条待办已不存在。") }
        var links = item.meetingLinks ?? []; links.removeAll { $0.id == link.id }; links.append(link); item.meetingLinks = links
        var receipts = item.meetingActionReceipts ?? []; receipts.append(MeetingActionReceipt(meetingID: link.meetingID, candidateID: candidateID, joinedAt: at)); item.meetingActionReceipts = receipts
        try commit(items.map { $0.id == taskID ? item : $0 }); return item
    }
}
