//
// HomeView.swift
//
// NightShift's only screen: the facility map with the route, a top bar (name,
// glasses status, settings), and a bottom card that always says what to check first.
// Everything else lives in Settings behind the gear. The glasses camera view model is
// owned here so the stream (and its vision checks) keeps running while the map shows.
//

import MWDATCore
import SwiftUI

struct HomeView: View {
  var wearablesVM: WearablesViewModel
  var controller = NightShiftController.shared
  @State private var cameraVM: CameraViewModel
  @State private var showSettings = false
  @State private var isListExpanded = false
  @State private var confirmEndShift = false

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearablesVM = wearablesVM
    self._cameraVM = State(wrappedValue: CameraViewModel(wearables: wearables))
  }

  /// Rank 1 from GET /map (the backend's order), if it needs checking.
  private var checkFirst: MapFacility? {
    controller.map?.facilities.first.flatMap { $0.needsCheck ? $0 : nil }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      ZStack(alignment: .bottomLeading) {
        FacilityMapView(controller: controller, isListExpanded: $isListExpanded)
        listToggle
          .padding(12)
      }
      bottomCard
    }
    .onAppear {
      // Vision checks and voice-flag photos read frames from the glasses stream.
      controller.attachCamera(
        frame: { [cameraVM] in cameraVM.currentVideoFrame },
        isStreaming: { [cameraVM] in cameraVM.isStreaming }
      )
    }
    .sheet(isPresented: $showSettings) {
      SettingsView(controller: controller, wearablesVM: wearablesVM, cameraVM: cameraVM)
    }
    .confirmationDialog("End your shift?", isPresented: $confirmEndShift, titleVisibility: .visible) {
      Button("End shift and send report", role: .destructive) {
        Task { await controller.endShift() }
      }
    }
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(spacing: 12) {
      Text("NightShift")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      Spacer()
      glassesIndicator
      Button {
        showSettings = true
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.title2)
          .frame(width: 56, height: 56)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Settings")
    }
    .padding(.leading, 16)
    .padding(.trailing, 4)
    .background(.bar)
  }

  private var glassesIndicator: some View {
    let connected = cameraVM.hasActiveDevice
    return HStack(spacing: 6) {
      Circle()
        .fill(connected ? Color.green : Color.gray)
        .frame(width: 12, height: 12)
      Image(systemName: "eyeglasses")
        .font(.title3)
        .foregroundStyle(connected ? Color.green : Color.gray)
    }
    .frame(minWidth: 56, minHeight: 56)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(connected ? "Glasses connected" : "Glasses not connected")
  }

  // MARK: - List toggle

  private var listToggle: some View {
    Button {
      isListExpanded.toggle()
    } label: {
      Label(isListExpanded ? "Hide list" : "Show list", systemImage: isListExpanded ? "chevron.down" : "list.number")
        .font(.headline)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.regularMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isListExpanded ? "Hide the list of places" : "Show the list of places in visit order")
  }

  // MARK: - Bottom card

  private var bottomCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        if let facility = checkFirst {
          Text("Check first: \(facility.displayName)")
            .font(.title3.bold())
          if let reason = facility.reasons.first {
            Text(reason)
              .font(.body)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
        } else if controller.map == nil {
          Text(controller.isLoadingMap ? "Loading the map…" : "Waiting for the map")
            .font(.title3.bold())
        } else {
          Text("Nothing needs checking right now")
            .font(.title3.bold())
        }
      }
      .accessibilityElement(children: .combine)

      HStack(spacing: 12) {
        Button {
          if let text = checkFirst?.spokenText {
            Task { await Speaker.shared.speak(text) }
          }
        } label: {
          Label("Read aloud", systemImage: "speaker.wave.2.fill")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .disabled(checkFirst?.spokenText == nil)
        .accessibilityLabel("Read aloud what to check first")

        shiftButton
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  /// Start shift / End shift, using the existing shift logic. A shift left open by an
  /// earlier launch shows "Continue shift".
  @ViewBuilder
  private var shiftButton: some View {
    if controller.isOnShift {
      Button {
        confirmEndShift = true
      } label: {
        Label("End shift", systemImage: "moon.zzz.fill")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 56)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .accessibilityLabel("End shift")
    } else if controller.unfinishedShiftStart != nil {
      Button {
        Task { await controller.resumeShift() }
      } label: {
        Label("Continue shift", systemImage: "play.fill")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 56)
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
      .accessibilityLabel("Continue the shift you started earlier")
    } else {
      Button {
        Task { await controller.startShift() }
      } label: {
        Label("Start shift", systemImage: "sunset.fill")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 56)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityLabel("Start shift")
    }
  }
}
