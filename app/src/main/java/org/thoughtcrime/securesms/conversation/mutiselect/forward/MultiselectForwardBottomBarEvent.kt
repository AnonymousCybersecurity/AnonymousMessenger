/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.thoughtcrime.securesms.conversation.mutiselect.forward

sealed interface MultiselectForwardBottomBarEvent {
  data class AddMessageUpdate(val message: String) : MultiselectForwardBottomBarEvent
  data object SendClick : MultiselectForwardBottomBarEvent
}
