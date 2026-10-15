/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.mediasend.select

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.signal.core.models.media.Media
import org.signal.core.util.logging.Log
import java.io.IOException

/** Reads only the images and videos explicitly granted by a system picker. */
object SystemMediaPicker {
  private val TAG = Log.tag(SystemMediaPicker::class.java)
  private val permissionOwners = mutableMapOf<Uri, MutableSet<Any>>()

  suspend fun readMedia(context: Context, uris: List<Uri>, owner: Any): List<Media> = withContext(Dispatchers.IO) {
    uris.distinct().mapNotNull { uri ->
      try {
        readMedia(context, uri, owner).also { if (it == null) releasePermission(context, owner, uri) }
      } catch (e: IOException) {
        releasePermission(context, owner, uri)
        Log.w(TAG, "Unable to read selected media", e)
        null
      } catch (e: SecurityException) {
        releasePermission(context, owner, uri)
        Log.w(TAG, "Selected media is no longer accessible", e)
        null
      } catch (e: IllegalArgumentException) {
        releasePermission(context, owner, uri)
        Log.w(TAG, "Unsupported selected media", e)
        null
      }
    }
  }

  @Synchronized
  fun retainPermissions(context: Context, owner: Any, uris: Collection<Uri>) {
    uris.distinct().forEach { uri ->
      if (!permissionOwners.getOrPut(uri) { mutableSetOf() }.add(owner)) return@forEach
      try {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
      } catch (e: SecurityException) {
        Log.w(TAG, "Provider only granted temporary access to selected media", e)
      }
    }
  }

  @Synchronized
  fun releaseUnusedPermissions(context: Context, owner: Any, retainedUris: Collection<Uri> = emptyList()) {
    val retained = retainedUris.toSet()
    permissionOwners.keys.toList().filterNot { it in retained }.forEach { releasePermission(context, owner, it) }
  }

  @Synchronized
  fun isPickerUri(uri: Uri): Boolean = permissionOwners.containsKey(uri)

  @Synchronized
  private fun releasePermission(context: Context, owner: Any, uri: Uri) {
    val owners = permissionOwners[uri] ?: return
    // Another open media flow can still need the same selected file.
    if (!owners.remove(owner) || owners.isNotEmpty()) return
    permissionOwners.remove(uri)
    try {
      context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } catch (e: SecurityException) {
      Log.w(TAG, "Selected-file permission was already revoked", e)
    }
  }

  private fun readMedia(context: Context, uri: Uri, owner: Any): Media? {
    val resolver = context.contentResolver
    val mimeType = resolver.getType(uri) ?: return null
    if (!mimeType.startsWith("image/") && !mimeType.startsWith("video/")) return null

    // The owning media flow releases this grant after cancellation or a safe handoff.
    retainPermissions(context, owner, listOf(uri))

    var size = 0L
    var fileName: String? = null
    resolver.query(uri, arrayOf(OpenableColumns.SIZE, OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) {
        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
        if (nameColumn >= 0) fileName = cursor.getString(nameColumn)
      }
    }

    var width = 0
    var height = 0
    var duration = 0L
    if (mimeType.startsWith("video/")) {
      val retriever = MediaMetadataRetriever()
      try {
        retriever.setDataSource(context, uri)
        width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        if (rotation == 90 || rotation == 270) {
          val originalWidth = width
          width = height
          height = originalWidth
        }
      } catch (e: RuntimeException) {
        throw IOException("Unable to read selected video metadata", e)
      } finally {
        retriever.release()
      }
    } else {
      val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
      resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
      width = bounds.outWidth.coerceAtLeast(0)
      height = bounds.outHeight.coerceAtLeast(0)
      val orientation = try {
        resolver.openInputStream(uri)?.use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
      } catch (e: IOException) {
        null
      }
      if (orientation == ExifInterface.ORIENTATION_ROTATE_90 || orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
        orientation == ExifInterface.ORIENTATION_TRANSPOSE || orientation == ExifInterface.ORIENTATION_TRANSVERSE
      ) {
        val originalWidth = width
        width = height
        height = originalWidth
      }
    }

    return Media(uri, mimeType, System.currentTimeMillis(), width, height, size.coerceAtLeast(0), duration, false, false, Media.ALL_MEDIA_BUCKET_ID, null, null, fileName)
  }
}
