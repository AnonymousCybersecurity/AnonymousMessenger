/*
 * Copyright 2023 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.thoughtcrime.securesms.conversation.v2.keyboard

import android.os.Bundle
import android.view.View
import androidx.core.os.bundleOf
import androidx.fragment.app.setFragmentResult
import androidx.lifecycle.ViewModelProvider
import io.reactivex.rxjava3.android.schedulers.AndroidSchedulers
import io.reactivex.rxjava3.kotlin.subscribeBy
import org.signal.core.models.media.Media
import org.signal.core.ui.logging.LoggingFragment
import org.signal.core.util.concurrent.LifecycleDisposable
import org.signal.core.util.concurrent.addTo
import org.thoughtcrime.securesms.R
import org.thoughtcrime.securesms.conversation.AttachmentKeyboard
import org.thoughtcrime.securesms.conversation.AttachmentKeyboardButton
import org.thoughtcrime.securesms.conversation.v2.ConversationViewModel
import org.thoughtcrime.securesms.recipients.Recipient

/**
 * Fragment wrapped version of [AttachmentKeyboard] to help encapsulate logic the view
 * needs from external sources.
 */
class AttachmentKeyboardFragment : LoggingFragment(R.layout.attachment_keyboard_fragment), AttachmentKeyboard.Callback {

  companion object {
    const val RESULT_KEY = "AttachmentKeyboardFragmentResult"
    const val MEDIA_RESULT = "Media"
    const val BUTTON_RESULT = "Button"
  }

  private lateinit var conversationViewModel: ConversationViewModel
  private lateinit var attachmentKeyboardView: AttachmentKeyboard

  private val lifecycleDisposable = LifecycleDisposable()

  @Suppress("ReplaceGetOrSet")
  override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    super.onViewCreated(view, savedInstanceState)
    lifecycleDisposable.bindTo(viewLifecycleOwner)

    attachmentKeyboardView = view.findViewById(R.id.attachment_keyboard)
    attachmentKeyboardView.apply {
      setCallback(this@AttachmentKeyboardFragment)
    }

    conversationViewModel = ViewModelProvider(requireParentFragment()).get(ConversationViewModel::class.java)

    val snapshot = conversationViewModel.recipientSnapshot
    if (snapshot != null) {
      updateButtonsAvailable(snapshot)
    }

    conversationViewModel
      .recipient
      .observeOn(AndroidSchedulers.mainThread())
      .subscribeBy {
        attachmentKeyboardView.setWallpaperEnabled(it.hasWallpaper)
        updateButtonsAvailable(it)
      }
      .addTo(lifecycleDisposable)
  }

  override fun onAttachmentMediaClicked(media: Media) {
    setFragmentResult(RESULT_KEY, bundleOf(MEDIA_RESULT to media))
  }

  override fun onAttachmentSelectorClicked(button: AttachmentKeyboardButton) {
    setFragmentResult(RESULT_KEY, bundleOf(BUTTON_RESULT to button))
  }

  override fun onAttachmentPickerRequested() {
    onAttachmentSelectorClicked(AttachmentKeyboardButton.GALLERY)
  }

  private fun updateButtonsAvailable(recipient: Recipient) {
    // ANONYMOUS: No-op
  }
}
