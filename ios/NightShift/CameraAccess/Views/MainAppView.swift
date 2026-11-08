/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Root view: NightShift's single home screen (map, route, check-first card).
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  var viewModel: WearablesViewModel

  var body: some View {
    // NightShift has one screen. Connecting the glasses (Meta AI registration) is in
    // its Settings, so the map and alarms work before the glasses are linked.
    HomeView(wearables: wearables, wearablesVM: viewModel)
  }
}
