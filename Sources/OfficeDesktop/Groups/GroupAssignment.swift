import Foundation

public enum GroupAssignment: Equatable {
    case inherit
    case explicit(UUID?)
}
