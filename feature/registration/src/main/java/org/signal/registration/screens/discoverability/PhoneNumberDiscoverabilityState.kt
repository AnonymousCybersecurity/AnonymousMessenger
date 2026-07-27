/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.registration.screens.discoverability

data class PhoneNumberDiscoverabilityState(
  val discoverable: Boolean = true,
  val showNobodyConfirmation: Boolean = false
)
