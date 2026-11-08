//
// RootTabView.swift
//
// NightShift's root: a four-tab TabView (To-do, Map, Alerts, Settings) in the web
// dashboard's flat dark style. The system tab bar is replaced by a flat one with a 2 pt
// blue underline on the active tab and an unresolved-count badge on Alerts. Every tab
// gets the red offline banner when the backend is unreachable, and the whole screen
// gets a 4 pt red border while the backend reports an alarm. The glasses camera view
// model is owned here so the stream and its vision checks keep running on any tab.
//

import MWDATCore
import SwiftUI
import UIKit

struct RootTabView: View {
  enum AppTab: Hashable { case todo, map, alerts, settings }

  var wearablesVM: WearablesViewModel
  var controller = NightShiftController.shared
  var network = NetworkMonitor.shared
  var backend = BackendStatus.shared
  @State private var cameraVM: CameraViewModel
  @State private var tab = AppTab.todo

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearablesVM = wearablesVM
    self._cameraVM = State(wrappedValue: CameraViewModel(wearables: wearables))
  }

  /// The backend says there's an alarm right now (flashing or already acknowledged).
  private var alarmActive: Bool { controller.alarm.backendStatus?.alarm == true }

  private var isOffline: Bool {
    !network.isConnected || (backend.isUnreachable && !Config.useMock)
  }

  var body: some View {
    VStack(spacing: 0) {
      if controller.alarm.monitoringLost {
        MonitoringLostBanner(lastSuccess: controller.alarm.lastSuccess)
      } else if isOffline {
        OfflineBanner()
      }
      TabView(selection: $tab) {
        TodoView(controller: controller, glassesConnected: cameraVM.hasActiveDevice, alarmActive: alarmActive)
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.todo)
        VStack(spacing: 0) {
          HeaderStrip(alarmActive: alarmActive) {
            Text("Map")
              .font(.title2.bold())
              .foregroundStyle(NS.textPrimary)
              .frame(minHeight: 40)
              .accessibilityAddTraits(.isHeader)
          }
          MapTabView(controller: controller)
        }
        .toolbar(.hidden, for: .tabBar)
        .tag(AppTab.map)
        AlertsView(controller: controller, alarmActive: alarmActive)
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.alerts)
        SettingsView(controller: controller, wearablesVM: wearablesVM, cameraVM: cameraVM, alarmActive: alarmActive)
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.settings)
      }
      tabBar
    }
    .background(NS.background)
    .overlay {
      if alarmActive {
        Rectangle()
          .strokeBorder(NS.alarmRed, lineWidth: 4)
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .preferredColorScheme(.dark)
    .tint(NS.accent)
    // Keep the screen awake on To-do and Alerts: a sleeping phone can miss alarms.
    .onChange(of: tab, initial: true) {
      UIApplication.shared.isIdleTimerDisabled = tab == .todo || tab == .alerts
    }
    .onAppear {
      // Vision checks and voice-flag photos read frames from the glasses stream.
      controller.attachCamera(
        frame: { [cameraVM] in cameraVM.currentVideoFrame },
        isStreaming: { [cameraVM] in cameraVM.isStreaming }
      )
    }
  }

  // MARK: - Tab bar

  private var tabBar: some View {
    HStack(spacing: 0) {
      tabButton(.todo, title: "To-do", icon: "checklist")
      tabButton(.map, title: "Map", icon: "map")
      tabButton(.alerts, title: "Alerts", icon: "bell", badge: controller.unresolvedCount)
      tabButton(.settings, title: "Settings", icon: "gearshape")
    }
    .background(NS.background)
    .overlay(alignment: .top) {
      Rectangle().fill(alarmActive ? NS.alarmRed : NS.border).frame(height: 1)
    }
  }

  private func tabButton(_ value: AppTab, title: String, icon: String, badge: Int = 0) -> some View {
    let selected = tab == value
    return Button {
      Haptics.tap()
      tab = value
    } label: {
      VStack(spacing: 4) {
        Rectangle()
          .fill(selected ? NS.accent : Color.clear)
          .frame(height: 2)
        ZStack(alignment: .topTrailing) {
          Image(systemName: selected ? "\(icon).fill" : icon)
            .font(.title3)
            .frame(width: 32, height: 26)
          if badge > 0 {
            Text("\(badge)")
              .font(.caption2.bold().monospacedDigit())
              .foregroundStyle(NS.textPrimary)
              .padding(.horizontal, 4)
              .frame(minWidth: 18, minHeight: 16)
              .background(NS.red)
              .offset(x: 10, y: -4)
          }
        }
        Text(title)
          .font(.caption.weight(.medium))
      }
      .foregroundStyle(selected ? NS.textPrimary : NS.textSecondary)
      .frame(maxWidth: .infinity, minHeight: NS.tap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(badge > 0 ? "\(title), \(badge) unresolved" : title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
