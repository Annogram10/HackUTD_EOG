//
// RootTabView.swift
//
// NightShift's root: three tabs (LIVE, SHIFT, SETTINGS) under one header on every
// screen ("NightShift" + "AVON NEVER SLEEPS" + the glasses link chip). Under the
// header: the LIVE/REPLAY/OFFLINE pill and any monitoring-lost or offline banner. The
// whole screen gets a 4 pt red border while the backend reports an alarm. The glasses
// camera view model is owned here so the stream and its vision checks keep running on
// any tab.
//

import MWDATCore
import SwiftUI
import UIKit

struct RootTabView: View {
  enum AppTab: Hashable { case live, shift, settings }

  var wearablesVM: WearablesViewModel
  var controller = NightShiftController.shared
  var network = NetworkMonitor.shared
  var backend = BackendStatus.shared
  @State private var cameraVM: CameraViewModel
  @State private var tab = AppTab.live
  @State private var showConnection = false

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
      AppHeader(alarmActive: alarmActive) {
        LinkStatusChip(cameraVM: cameraVM, wearablesVM: wearablesVM) { showConnection = true }
      }
      DangerBanner(controller: controller)
      HStack(spacing: 8) {
        ModePill(clock: controller.serverClock, reachable: controller.isBackendReachable)
        if let dataset = controller.serverClock?.dataset {
          Text(dataset)
            .font(.nsMono(.caption))
            .foregroundStyle(NS.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .background(NS.background)
      if controller.alarm.monitoringLost {
        MonitoringLostBanner(lastSuccess: controller.alarm.lastSuccess, reason: controller.alarm.lastFailureReason)
      } else if isOffline {
        OfflineBanner()
      }
      TabView(selection: $tab) {
        LiveView(controller: controller, cameraVM: cameraVM, wearablesVM: wearablesVM)
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.live)
        ShiftTabView(controller: controller)
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.shift)
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
    // Rajdhani for any text without its own font.
    .font(.ns(.body))
    .tint(NS.accent)
    // Keep the screen awake on LIVE and SHIFT: a sleeping phone can miss alarms.
    .onChange(of: tab, initial: true) {
      UIApplication.shared.isIdleTimerDisabled = tab == .live || tab == .shift
    }
    .sheet(isPresented: $showConnection) {
      ConnectionSheet(controller: controller, cameraVM: cameraVM, wearablesVM: wearablesVM)
        .presentationDetents([.medium, .large])
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
      tabButton(.live, title: "Live", icon: "eyeglasses")
      tabButton(.shift, title: "Shift", icon: "list.bullet.rectangle", badge: controller.unresolvedCount)
      tabButton(.settings, title: "Settings", icon: "gearshape")
    }
    .background(NS.background)
    .overlay(alignment: .top) {
      Rectangle().fill(alarmActive ? NS.alarmRed : NS.hud.opacity(0.6)).frame(height: 1)
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
          Image(systemName: icon)
            .font(.system(size: 20, weight: selected ? .semibold : .regular))
            .frame(width: 32, height: 26)
          if badge > 0 {
            Text("\(badge)")
              .font(.nsMono(.caption2, .bold))
              .foregroundStyle(NS.onFill)
              .padding(.horizontal, 4)
              .frame(minWidth: 18, minHeight: 16)
              .background(NS.red)
              .offset(x: 10, y: -4)
          }
        }
        Text(title.uppercased())
          .font(.ns(.footnote, .bold))
          .tracking(0.8)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
      .foregroundStyle(selected ? NS.accent : NS.textMuted)
      .frame(maxWidth: .infinity, minHeight: NS.tap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(badge > 0 ? "\(title), \(badge) unresolved" : title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The header on every screen: "Night" (periwinkle) "Shift" (salmon) in Big Shoulders
/// Stencil, the "AVON NEVER SLEEPS" tagline, and a trailing slot for the link chip.
struct AppHeader<Trailing: View>: View {
  let alarmActive: Bool
  @ViewBuilder let trailing: Trailing

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 0) {
          (Text("Night").foregroundStyle(NS.accent) + Text("Shift").foregroundStyle(NS.primary))
            .font(.nsDisplay(.title))
            .accessibilityLabel("NightShift")
            .accessibilityAddTraits(.isHeader)
          Text("AVON NEVER SLEEPS")
            .font(.nsMono(.caption2))
            .tracking(1.2)
            .foregroundStyle(NS.textMuted)
            .accessibilityHidden(true)
        }
        Spacer(minLength: 8)
        trailing
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      Rectangle()
        .fill(alarmActive ? NS.alarmRed : NS.hud.opacity(0.6))
        .frame(height: alarmActive ? 2 : 1)
    }
    .background(NS.background)
  }
}
