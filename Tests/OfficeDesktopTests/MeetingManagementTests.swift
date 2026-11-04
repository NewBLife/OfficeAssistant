import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct MeetingManagementTests {
    @Test func deletionPersistsAndOnlyRemovesTargetMeetingData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meetings.store")
        let target = MeetingSession(title: "删除", configuration: AIConfiguration())
        let other = MeetingSession(title: "保留", configuration: AIConfiguration())
        let tasks = TaskStore(repository: MemoryRepository())
        var task = TaskItem(title: "已加入待办")
        task.meetingLinks = [TaskMeetingLink(meetingID: target.id, meetingTitleSnapshot: target.title)]
        try tasks.upsert(task)
        do {
            let repo = try CoreDataMeetingRepository(url: url)
            for meeting in [target, other] {
                try repo.save(meeting)
                try repo.upsert(TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)))
                try repo.save(document: MinutesDocument(meetingID: meeting.id, meetingTitle: meeting.title, options: MinutesOptions()), candidates: [ActionCandidate(meetingID: meeting.id, titleZH: "行动项", evidence: [])])
                try repo.saveJob(MinutesJobRecord(meetingID: meeting.id, options: MinutesOptions(), sourceFingerprint: "test"))
            }
            let controller = MeetingSessionController(repository: repo, credentials: TestCredentials())
            try controller.open(target)
            try controller.delete(target.id)
            #expect(controller.meeting == nil && controller.segments.isEmpty)
            #expect(controller.history.map(\.id) == [other.id])
        }
        let reopened = try CoreDataMeetingRepository(url: url)
        #expect(try reopened.list().map(\.id) == [other.id])
        #expect(try reopened.segments(meetingID: target.id).isEmpty)
        #expect(try reopened.documents(meetingID: target.id).isEmpty)
        #expect(try reopened.candidates(meetingID: target.id).isEmpty)
        #expect(try reopened.jobs(meetingID: target.id).isEmpty)
        #expect(try reopened.segments(meetingID: other.id).count == 1)
        #expect(try reopened.documents(meetingID: other.id).count == 1)
        #expect(try reopened.candidates(meetingID: other.id).count == 1)
        #expect(try reopened.jobs(meetingID: other.id).count == 1)
        #expect(tasks.items.map(\.id) == [task.id])
    }
    @Test func deletionDoesNotAllowLateMinutesToReappear() async throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var meeting = MeetingSession(title: "纪要生成中", configuration: AIConfiguration()); meeting.state = .completed
        try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0))
        segment.finalText = "测试发言"; try repo.upsert(segment)
        let generator = FakeMinutesGenerator(); generator.held = true
        let minutes = MinutesCoordinator(meetings: repo, notes: repo, generator: generator)
        let operation = Task { try await minutes.generate(meetingID: meeting.id, options: MinutesOptions()) }
        for _ in 0..<100 where generator.release == nil { await Task.yield() }
        let release = try #require(generator.release)
        minutes.forget(meetingID: meeting.id)
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials())
        try controller.delete(meeting.id)
        release.resume()
        _ = await operation.result
        #expect(try repo.list().isEmpty)
        #expect(try repo.documents(meetingID: meeting.id).isEmpty)
        #expect(try repo.jobs(meetingID: meeting.id).isEmpty)
        #expect(minutes.currentJob == nil)
    }
    @Test func deletionRejectsRecordingAndUnclosedRemoteTasks() async throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), factory: { _, _ in TestRecognizer() }, captureFactory: { _ in [(.microphone, TestCapture())] })
        try await controller.start(MeetingSetup(title: "正在录音", configuration: AIConfiguration()))
        let id = try #require(controller.meeting?.id)
        #expect(throws: (any Error).self) { try controller.delete(id) }
        #expect(try repo.list().count == 1)
        await controller.stop()
        var meeting = try #require(repo.list().first)
        meeting.remoteTasks = [RemoteTask(taskID: "unclosed", source: .microphone)]
        try repo.save(meeting)
        #expect(throws: (any Error).self) { try controller.delete(id) }
        #expect(try repo.list().count == 1)
    }
}

@Suite struct MeetingAudioFilesTests {
    @Test func exportPreservesOriginalsAndSeparatesAllSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MeetingAudioFiles(root: root)
        let original = root.appendingPathComponent("original.m4a")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: original)
        let imported = try manager.retainImport(original, meetingID: UUID())
        let microphone = "microphone.wav"; try Data([5, 6]).write(to: root.appendingPathComponent(microphone))
        let names = [imported, microphone]
        let exported = try manager.export(names, title: "讨论/会议", to: root)
        #expect(try Data(contentsOf: exported.appendingPathComponent(imported)) == bytes)
        #expect(try Data(contentsOf: exported.appendingPathComponent(microphone)) == Data([5, 6]))
        #expect(try Data(contentsOf: original) == bytes)
        try manager.remove(names)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(imported).path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent(imported).path))
    }
    @Test func missingAudioAndUnsafePathsFailWithoutPartialExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MeetingAudioFiles(root: root)
        try Data([1]).write(to: root.appendingPathComponent("exists.wav"))
        #expect(throws: (any Error).self) { try manager.export([], title: "会议", to: root) }
        #expect(throws: (any Error).self) { try manager.export(["exists.wav", "missing.wav"], title: "会议", to: root) }
        #expect(throws: (any Error).self) { try manager.remove(["../outside.wav"]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["exists.wav"])
    }
}
