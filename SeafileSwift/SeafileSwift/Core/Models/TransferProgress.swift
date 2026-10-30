import Foundation

struct TransferProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case running
        case finished
        case failed(String)
    }

    var state: State = .queued
    var fraction: Double = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    var isActive: Bool {
        switch state {
        case .queued, .running: return true
        case .finished, .failed: return false
        }
    }
}
