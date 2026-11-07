//
// NetworkMonitor.swift
//
// Publishes whether the phone currently has a usable network path.
//

import Foundation
import Network
import Observation

@Observable
@MainActor
final class NetworkMonitor {
  static let shared = NetworkMonitor()

  private(set) var isConnected: Bool = true

  @ObservationIgnored private let monitor = NWPathMonitor()
  @ObservationIgnored private var observers: [UUID: @MainActor (Bool) -> Void] = [:]

  private init() {
    // `@Sendable` keeps this closure off the main actor; NWPathMonitor calls it on its own queue.
    monitor.pathUpdateHandler = { @Sendable path in
      let connected = path.status == .satisfied
      Task { @MainActor in NetworkMonitor.shared.update(connected) }
    }
    monitor.start(queue: DispatchQueue(label: "NightShift.NetworkMonitor"))
  }

  /// Calls `handler` whenever connectivity changes. Returns a key for `removeObserver`.
  @discardableResult
  func addObserver(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
    let key = UUID()
    observers[key] = handler
    return key
  }

  func removeObserver(_ key: UUID) {
    observers[key] = nil
  }

  private func update(_ connected: Bool) {
    guard connected != isConnected else { return }
    isConnected = connected
    observers.values.forEach { $0(connected) }
  }
}
