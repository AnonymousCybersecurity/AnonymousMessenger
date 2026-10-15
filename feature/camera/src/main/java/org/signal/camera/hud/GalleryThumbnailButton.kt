/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.camera.hud

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import org.signal.camera.R

/** Opens media selection without reading the device's photo/video library. */
@Composable
fun GalleryThumbnailButton(
  modifier: Modifier = Modifier,
  onClick: () -> Unit
) {
  Box(
    modifier = modifier
      .size(52.dp)
      .clip(CircleShape)
      .border(2.dp, Color.White, CircleShape)
      .background(Color.Black.copy(alpha = 0.3f), CircleShape)
      .clickable(onClick = onClick),
    contentAlignment = Alignment.Center
  ) {
    Icon(
      imageVector = Icons.Outlined.PhotoLibrary,
      contentDescription = stringResource(R.string.GalleryThumbnailButton__choose_photos_and_videos),
      tint = Color.White,
      modifier = Modifier.size(24.dp)
    )
  }
}
