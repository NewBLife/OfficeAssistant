import Foundation
import OfficeCore

@MainActor public final class MeetingTaskLinkService {
    public let tasks: TaskStore
    private let notes: any MinutesRepository; private let meetings: any MeetingRepository
    public init(tasks: TaskStore, notes: any MinutesRepository, meetings: any MeetingRepository) { self.tasks = tasks; self.notes = notes; self.meetings = meetings }
    public func accept(_ candidate: ActionCandidate, editedTask: TaskItem, allowDuplicate: Bool = false) throws -> UUID {
        if let existing = tasks.taskForCandidate(meetingID: candidate.meetingID, candidateID: candidate.id) { try markAccepted(candidate, taskID: existing.id); return existing.id }
        try validate(candidate, allowDuplicate: allowDuplicate)
        guard !candidate.clarifications.contains(.commitment), !candidate.clarifications.contains(.crossChunkReview) else { throw OfficeError.invalid("请先逐项核对承诺及全场后续变更，再确认加入。") }
        let link = try sourceLink(candidate)
        let task = try tasks.acceptMeetingAction(editedTask, candidateID: candidate.id, link: link, at: Date())
        try markAccepted(candidate, taskID: task.id); return task.id
    }
    public func associate(candidate: ActionCandidate, existingTaskID: UUID) throws -> UUID {
        try validate(candidate, allowDuplicate: true)
        let task = try tasks.associateMeetingAction(taskID: existingTaskID, candidateID: candidate.id, link: sourceLink(candidate), at: Date())
        try markAccepted(candidate, taskID: task.id); return task.id
    }
    private func validate(_ candidate: ActionCandidate, allowDuplicate: Bool) throws {
        guard let stored = try notes.candidates(meetingID: candidate.meetingID).first(where: { $0.id == candidate.id }), stored.reviewState != .ignored else { throw OfficeError.invalid("行动项已变化或被忽略，请重新打开。") }
        if stored.reviewState == .accepted && tasks.taskForCandidate(meetingID: candidate.meetingID, candidateID: candidate.id) == nil { throw OfficeError.invalid("已加入的待办已被删除，请手动新建，避免自动重建。") }
        if !allowDuplicate && candidate.clarifications.contains(.possibleDuplicate) { throw OfficeError.invalid("这项可能已存在，请关联已有待办或明确确认是独立事项。") }
        let segments = try meetings.segments(meetingID: candidate.meetingID)
        guard !candidate.evidence.isEmpty, candidate.evidence.allSatisfy({ ref in segments.contains { $0.id == ref.segmentID && $0.revision == ref.revision && ($0.finalText ?? "").contains(ref.quote) } }) else { throw OfficeError.invalid("依据原文已变化，请重新提取或校对行动项。") }
    }
    private func sourceLink(_ candidate: ActionCandidate) throws -> TaskMeetingLink {
        guard let meeting = try meetings.list().first(where: { $0.id == candidate.meetingID }) else { throw OfficeError.invalid("来源会议不可用。") }
        return TaskMeetingLink(meetingID: meeting.id, meetingTitleSnapshot: meeting.title, candidateID: candidate.id, evidence: candidate.evidence)
    }
    private func markAccepted(_ candidate: ActionCandidate, taskID: UUID) throws {
        var values = try notes.candidates(meetingID: candidate.meetingID)
        guard let index = values.firstIndex(where: { $0.id == candidate.id }) else { throw OfficeError.invalid("待办已保存，候选状态尚未更新，请重新打开。") }
        values[index].reviewState = .accepted; values[index].acceptedTaskID = taskID
        do { try notes.saveCandidates(values, meetingID: candidate.meetingID) }
        catch { throw OfficeError.invalid("待办已保存，行动项状态暂未更新；重试不会重复创建。") }
    }
}
