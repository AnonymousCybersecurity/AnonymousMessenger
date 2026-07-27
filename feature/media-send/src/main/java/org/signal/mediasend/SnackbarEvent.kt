/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.mediasend

import androidx.annotation.StringRes
import org.signal.core.ui.compose.Snackbars

internal data class SnackbarEvent(
  @get:StringRes val message: Int,
  val duration: Snackbars.Duration = Snackbars.Duration.SHORT
)
