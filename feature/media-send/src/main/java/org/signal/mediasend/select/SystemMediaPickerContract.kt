package org.signal.mediasend.select

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts

/** Chooses an available system picker before launching, including when the photo picker is disabled. */
class SystemMediaPickerContract(private val maxItems: Int) : ActivityResultContract<PickVisualMediaRequest, List<Uri>>() {

  override fun createIntent(context: Context, input: PickVisualMediaRequest): Intent {
    val photoIntent = if (maxItems == 1) {
      ActivityResultContracts.PickVisualMedia().createIntent(context, input)
    } else {
      ActivityResultContracts.PickMultipleVisualMedia(maxItems).createIntent(context, input)
    }
    if (photoIntent.resolveActivity(context.packageManager) != null) return photoIntent

    // Avoid a failed launch producing a cancellation while another picker is pending.
    val mimeTypes = when (val type = input.mediaType) {
      ActivityResultContracts.PickVisualMedia.ImageOnly -> arrayOf("image/*")
      ActivityResultContracts.PickVisualMedia.VideoOnly -> arrayOf("video/*")
      is ActivityResultContracts.PickVisualMedia.SingleMimeType -> arrayOf(type.mimeType)
      else -> arrayOf("image/*", "video/*")
    }
    return if (maxItems == 1) {
      ActivityResultContracts.OpenDocument().createIntent(context, mimeTypes)
    } else {
      ActivityResultContracts.OpenMultipleDocuments().createIntent(context, mimeTypes)
    }
  }

  override fun parseResult(resultCode: Int, intent: Intent?): List<Uri> {
    return ActivityResultContracts.OpenMultipleDocuments().parseResult(resultCode, intent)
  }
}
