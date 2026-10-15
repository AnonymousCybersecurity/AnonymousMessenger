package org.signal.mediasend.select

import android.app.Application
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class SystemMediaPickerTest {
  private val resolver = mockk<ContentResolver>(relaxed = true)
  private val application = mockk<Application> { every { contentResolver } returns resolver }
  private val firstOwner = Any()
  private val secondOwner = Any()
  private val firstUri = Uri.parse("content://picker/first")
  private val secondUri = Uri.parse("content://picker/second")
  private val readFlag = Intent.FLAG_GRANT_READ_URI_PERMISSION

  @After
  fun tearDown() {
    SystemMediaPicker.releaseUnusedPermissions(application, firstOwner)
    SystemMediaPicker.releaseUnusedPermissions(application, secondOwner)
  }

  @Test
  fun `a shared selection stays accessible until its last flow finishes`() {
    SystemMediaPicker.retainPermissions(application, firstOwner, listOf(firstUri))
    SystemMediaPicker.retainPermissions(application, secondOwner, listOf(firstUri))

    SystemMediaPicker.releaseUnusedPermissions(application, firstOwner)

    assertTrue(SystemMediaPicker.isPickerUri(firstUri))
    verify(exactly = 0) { resolver.releasePersistableUriPermission(firstUri, readFlag) }

    SystemMediaPicker.releaseUnusedPermissions(application, secondOwner)

    assertFalse(SystemMediaPicker.isPickerUri(firstUri))
    verify(exactly = 1) { resolver.releasePersistableUriPermission(firstUri, readFlag) }
  }

  @Test
  fun `rejected and deselected files release access while selected files retain it`() {
    SystemMediaPicker.retainPermissions(application, firstOwner, listOf(firstUri, secondUri))

    SystemMediaPicker.releaseUnusedPermissions(application, firstOwner, listOf(firstUri))

    assertTrue(SystemMediaPicker.isPickerUri(firstUri))
    assertFalse(SystemMediaPicker.isPickerUri(secondUri))
    verify(exactly = 0) { resolver.releasePersistableUriPermission(firstUri, readFlag) }
    verify(exactly = 1) { resolver.releasePersistableUriPermission(secondUri, readFlag) }
  }

  @Test
  fun `unreadable media releases the grant acquired before metadata failed`() = runTest {
    every { resolver.getType(firstUri) } returns "image/png"
    every { resolver.query(firstUri, any(), null, null, null) } throws IOException("File unavailable")

    assertTrue(SystemMediaPicker.readMedia(application, listOf(firstUri), firstOwner).isEmpty())

    assertFalse(SystemMediaPicker.isPickerUri(firstUri))
    verify(exactly = 1) { resolver.releasePersistableUriPermission(firstUri, readFlag) }
  }

  @Test
  fun `temporary grants still mark files for a safe local handoff`() {
    every { resolver.takePersistableUriPermission(firstUri, readFlag) } throws SecurityException("Temporary grant")

    SystemMediaPicker.retainPermissions(application, firstOwner, listOf(firstUri))

    assertTrue(SystemMediaPicker.isPickerUri(firstUri))
    SystemMediaPicker.releaseUnusedPermissions(application, firstOwner)
    assertFalse(SystemMediaPicker.isPickerUri(firstUri))
  }
}
