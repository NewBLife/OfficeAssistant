import Foundation
public enum MeetingNavigationPolicy {
    public static func validate(target: UUID, available: [UUID], activeMeetingID: UUID?) throws {
        guard available.contains(target) else { throw OfficeError.invalid("来源会议不可用，待办仍可正常使用。") }
        guard activeMeetingID == nil || activeMeetingID == target else { throw OfficeError.invalid("另一个会议正在记录，请先暂停或结束后再打开来源会议。") }
    }
}
