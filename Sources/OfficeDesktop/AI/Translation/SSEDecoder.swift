import Foundation
import OfficeCore

public struct SSEMessage: Equatable { public var data: String; public var event: String? }
public struct SSEDecoder {
    private var pending = Data(); private var dataLines: [String] = []; private var event: String?
    public init() {}
    public mutating func feed(_ bytes: Data) throws -> [SSEMessage] {
        pending.append(bytes)
        guard pending.count < 2_000_000 else { throw OfficeError.invalid("服务响应超过允许大小。") }
        var result: [SSEMessage] = []
        while let index = pending.firstIndex(of: 10) {
            let lineBytes = Data(pending[..<index]); pending.removeSubrange(...index)
            guard var line = String(data: lineBytes, encoding: .utf8) else { throw OfficeError.invalid("服务返回了无效文本编码。") }
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                if !dataLines.isEmpty { result.append(SSEMessage(data: dataLines.joined(separator: "\n"), event: event)) }
                dataLines = []; event = nil
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }; dataLines.append(value)
            } else if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
}
