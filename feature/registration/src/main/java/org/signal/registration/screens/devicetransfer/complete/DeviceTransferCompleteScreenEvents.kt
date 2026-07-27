/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.registration.screens.devicetransfer.complete

sealed class DeviceTransferCompleteScreenEvents {
  data object ContinueClicked : DeviceTransferCompleteScreenEvents()
  data object ConsumeOneTimeEvent : DeviceTransferCompleteScreenEvents()
}
