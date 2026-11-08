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
// Root view: NightShift's four tabs (To-do, Map, Alerts, Settings).
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  var viewModel: WearablesViewModel

  var body: some View {
    // Connecting the glasses (Meta AI registration) is in the Settings tab, so the
    // to-do list, map and alarms work before the glasses are linked.
    RootTabView(wearables: wearables, wearablesVM: viewModel)
  }
}
