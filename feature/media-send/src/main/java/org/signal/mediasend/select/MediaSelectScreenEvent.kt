/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.mediasend.select

import android.net.Uri
import org.signal.core.models.media.Media

sealed interface MediaSelectScreenEvent {
  data class MediaPicked(val uris: List<Uri>) : MediaSelectScreenEvent
  data class MediaClick(val media: Media) : MediaSelectScreenEvent
  data class SetFocusedMedia(val media: Media) : MediaSelectScreenEvent
  data object NavigateToEdit : MediaSelectScreenEvent
}
