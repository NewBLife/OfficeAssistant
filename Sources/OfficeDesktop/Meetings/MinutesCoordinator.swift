import Foundation
import Observation
import OfficeCore

@MainActor @Observable public final class MinutesCoordinator {
    public private(set) var changeCount = 0
    public private(set) var currentJob: MinutesJobRecord?
    public var errorMessage: String?
    public var isRunning: Bool { currentJob?.status == .running }
    @ObservationIgnored private let meetings: any MeetingRepository
    @ObservationIgnored private let notes: any MinutesRepository
    @ObservationIgnored private let generator: any MinutesGenerating
    @ObservationIgnored private let linkedTasks: () -> [TaskItem]
    @ObservationIgnored private let isRecording: (UUID) -> Bool
    @ObservationIgnored private var operation: Task<MinutesGenerationResult, Error>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var incremental: [UUID: MinutesOptions] = [:]
    @ObservationIgnored private var processed: [UUID: Set<String>] = [:]
    @ObservationIgnored private var lastIncremental: [UUID: Date] = [:]
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var incrementalTask: Task<Void, Never>?
    @ObservationIgnored private var incrementalTaskID = UUID()
    @ObservationIgnored private var incrementalJob = false
    public init(meetings: any MeetingRepository, notes: any MinutesRepository, generator: any MinutesGenerating, linkedTasks: @escaping () -> [TaskItem] = { [] }, isRecording: @escaping (UUID) -> Bool = { _ in false }) {
        self.meetings = meetings; self.notes = notes; self.generator = generator; self.linkedTasks = linkedTasks; self.isRecording = isRecording
        do { for var job in try notes.jobs(meetingID: nil) where job.status == .running { job.status = .interrupted; job.errorMessage = "上次生成已中断，可重新生成。"; try notes.saveJob(job) } }
        catch { errorMessage = "纪要作业状态无法读取，旧记录已保留。" }
    }
    public func documents(meetingID: UUID) throws -> [MinutesDocument] { _ = changeCount; return try notes.documents(meetingID: meetingID) }
    public func candidates(meetingID: UUID) throws -> [ActionCandidate] { _ = changeCount; return try notes.candidates(meetingID: meetingID) }
    public func refresh() { changeCount += 1 }
    private func snapshot(_ id: UUID) throws -> MinutesSnapshot {
        guard let meeting = try meetings.list().first(where: { $0.id == id }) else { throw OfficeError.invalid("来源会议不可用。") }
        return MinutesSnapshot(meeting: meeting, segments: try meetings.segments(meetingID: id))
    }
    public func isStale(_ document: MinutesDocument) -> Bool {
        guard var latest = try? snapshot(document.meetingID) else { return true }
        if latest.fingerprint == document.sourceFingerprint { return false }
        latest.meeting.title = document.meetingTitle
        return latest.fingerprint != document.sourceFingerprint
    }
    public func generate(meetingID: UUID, options: MinutesOptions) async throws { try await run(meetingID: meetingID, options: options, incrementalOnly: false) }
    private func run(meetingID: UUID, options: MinutesOptions, incrementalOnly: Bool) async throws {
        guard !isRunning else { throw OfficeError.invalid("已有纪要作业进行中，请稍后重试。") }
        guard incrementalOnly || !isRecording(meetingID) else { throw OfficeError.invalid("请先暂停或停止记录，再生成完整纪要。") }
        try options.validate()
        let full = try snapshot(meetingID); let previousID = try documents(meetingID: meetingID).first?.id
        var input = incrementalOnly ? MinutesSnapshot(meeting: full.meeting, segments: full.segments.filter { !(processed[meetingID] ?? []).contains(segmentKey($0)) }) : full
        input.knownActions = try notes.candidates(meetingID: meetingID)
        guard !input.segments.isEmpty else { throw OfficeError.invalid("没有已定稿原文，暂时无法生成纪要。") }
        var job = MinutesJobRecord(meetingID: meetingID, options: options, sourceFingerprint: input.fingerprint)
        try notes.saveJob(job)
        token = UUID(); let epoch = token; currentJob = job; errorMessage = nil; incrementalJob = incrementalOnly
        let task = Task { @MainActor in try await self.generator.generate(snapshot: input, options: options) }; operation = task
        let timeout = Task { try? await Task.sleep(for: .seconds(600)); if !Task.isCancelled { task.cancel() } }
        defer { timeout.cancel(); if epoch == token { operation = nil; incrementalJob = false } }
        do {
            var result = try await task.value; try Task.checkCancellation()
            guard epoch == token, !task.isCancelled else { throw CancellationError() }
            let latest = try snapshot(meetingID)
            let unchanged: Bool
            if incrementalOnly {
                unchanged = input.segments.allSatisfy { old in latest.segments.contains { $0.id == old.id && $0.revision == old.revision && $0.finalText == old.finalText } }
            } else { let latestID = try documents(meetingID: meetingID).first?.id; unchanged = latest.fingerprint == full.fingerprint && latestID == previousID }
            guard unchanged else { job.status = .stale; throw OfficeError.invalid("原文或纪要已更新，本次结果未替换旧记录，请重新生成。") }
            guard result.document.meetingID == meetingID, result.candidates.allSatisfy({ $0.meetingID == meetingID }) else { throw OfficeError.invalid("纪要来源不一致，结果未保存。") }
            if incrementalOnly {
                for index in result.candidates.indices {
                    for flag in [CandidateClarification.commitment, .crossChunkReview] where !result.candidates[index].clarifications.contains(flag) { result.candidates[index].clarifications.append(flag) }
                }
            }
            let values = CandidateRules.reconcile(existing: try notes.candidates(meetingID: meetingID), proposed: result.candidates, linkedTasks: linkedTasks(), replaceProposals: !incrementalOnly)
            if incrementalOnly { try notes.saveCandidates(values, meetingID: meetingID); processed[meetingID, default: []].formUnion(input.segments.map(segmentKey)); lastIncremental[meetingID] = Date() }
            else {
                result.document.id = UUID(); result.document.revision = (try documents(meetingID: meetingID).map(\.revision).max() ?? 0) + 1
                result.document.sourceFingerprint = full.fingerprint; result.document.options = options; result.document.participantsNote = full.meeting.participantsNote
                try notes.save(document: result.document, candidates: values)
            }
            job.status = .completed; try notes.saveJob(job); currentJob = job; changeCount += 1
        } catch {
            if epoch == token {
                if job.status != .stale { job.status = error is CancellationError ? .cancelled : .failed }
                job.errorMessage = ProviderNetwork.safeError(error); try? notes.saveJob(job); currentJob = job; errorMessage = job.errorMessage; changeCount += 1
            }
            throw error
        }
    }
    public func cancel(meetingID: UUID) {
        guard var job = currentJob, job.meetingID == meetingID, isRunning else { return }
        token = UUID(); operation?.cancel(); operation = nil; job.status = .cancelled; job.errorMessage = "已取消生成。"
        try? notes.saveJob(job); currentJob = job; changeCount += 1
    }
    public func forget(meetingID: UUID) {
        recordingStopped(meetingID: meetingID); cancel(meetingID: meetingID)
        processed.removeValue(forKey: meetingID); lastIncremental.removeValue(forKey: meetingID)
        if currentJob?.meetingID == meetingID { currentJob = nil }
        changeCount += 1
    }
    public func saveEdit(_ document: MinutesDocument) throws {
        var next = document; next.id = UUID(); next.revision = (try documents(meetingID: document.meetingID).map(\.revision).max() ?? 0) + 1
        next.createdAt = Date(); next.editedByUser = true
        try notes.save(document: next, candidates: notes.candidates(meetingID: next.meetingID)); changeCount += 1
    }
    public func saveCandidate(_ candidate: ActionCandidate) throws {
        var values = try notes.candidates(meetingID: candidate.meetingID)
        guard let index = values.firstIndex(where: { $0.id == candidate.id }), values[index].reviewState != .accepted else { throw OfficeError.invalid("行动项已加入待办，请在待办中修改。") }
        values[index] = candidate; try notes.saveCandidates(values, meetingID: candidate.meetingID); changeCount += 1
    }
    public func incrementalEnabled(meetingID: UUID) -> Bool { _ = changeCount; return incremental[meetingID] != nil }
    private func segmentKey(_ segment: TranscriptSegment) -> String { "\(segment.id.id).\(segment.revision):\(segment.text)" }
    public func setIncrementalExtraction(_ enabled: Bool, meetingID: UUID, options: MinutesOptions) {
        if enabled {
            incremental[meetingID] = options; processed[meetingID] = Set((try? snapshot(meetingID).segments.map(segmentKey)) ?? [])
        } else {
            incremental.removeValue(forKey: meetingID); wake?.cancel(); wake = nil
            if incrementalJob && currentJob?.meetingID == meetingID { cancel(meetingID: meetingID) }
            incrementalTask?.cancel(); incrementalTask = nil; incrementalTaskID = UUID()
        }
        changeCount += 1
    }
    public func recordingStopped(meetingID: UUID) { if let options = incremental[meetingID] { setIncrementalExtraction(false, meetingID: meetingID, options: options) } }
    public func noticeFinal(meetingID: UUID) {
        guard let options = incremental[meetingID], isRecording(meetingID), incrementalTask == nil else { return }
        guard let source = try? snapshot(meetingID), source.segments.filter({ !(processed[meetingID] ?? []).contains(segmentKey($0)) }).count >= 5 else { return }
        let delay = max(0, 60 - Date().timeIntervalSince(lastIncremental[meetingID] ?? .distantPast))
        if delay > 0 || isRunning {
            wake?.cancel(); wake = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(1, delay > 0 ? delay : 5)))
                guard !Task.isCancelled else { return }; self?.noticeFinal(meetingID: meetingID)
            }; return
        }
        let scheduled = UUID(); incrementalTaskID = scheduled
        incrementalTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.incrementalTaskID == scheduled, self.incremental[meetingID] != nil, self.isRecording(meetingID) else { return }
            var succeeded = false
            defer { if self.incrementalTaskID == scheduled { self.incrementalTask = nil; if succeeded { self.noticeFinal(meetingID: meetingID) } } }
            do { try await self.run(meetingID: meetingID, options: options, incrementalOnly: true); succeeded = true }
            catch { if self.incrementalTaskID == scheduled && !(error is CancellationError) { self.errorMessage = ProviderNetwork.safeError(error); self.incremental.removeValue(forKey: meetingID); self.changeCount += 1 } }
        }
    }
}
