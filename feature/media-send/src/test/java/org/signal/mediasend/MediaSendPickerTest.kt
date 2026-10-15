package org.signal.mediasend

import android.app.Application
import android.net.Uri
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModelStore
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.slot
import io.mockk.unmockkAll
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.signal.core.models.media.Media
import org.signal.mediasend.preupload.PreUploadController
import org.signal.mediasend.select.MediaSelectScreenEvent
import org.signal.mediasend.select.SystemMediaPicker
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class MediaSendPickerTest {
  private val dispatcher = StandardTestDispatcher()
  private val application = mockk<Application>(relaxed = true)
  private val repository = mockk<MediaSendRepository>(relaxed = true)
  private val preUploadController = mockk<PreUploadController>(relaxed = true)
  private val store = ViewModelStore()
  private var viewModel: MediaSendViewModel? = null
  private val first = video("first")
  private val second = video("second")

  @Before
  fun setUp() {
    Dispatchers.setMain(dispatcher)
    mockkObject(MediaSendDependencies, SystemMediaPicker)
    every { MediaSendDependencies.application } returns application
    every { SystemMediaPicker.retainPermissions(any(), any(), any()) } returns Unit
    every { SystemMediaPicker.releaseUnusedPermissions(any(), any(), any()) } returns Unit
    coEvery { repository.getStorySendRequirements(any()) } returns StorySendRequirements.CAN_SEND
  }

  @After
  fun tearDown() {
    store.clear()
    viewModel?.let { owner ->
      verify(timeout = 2000) { SystemMediaPicker.releaseUnusedPermissions(application, owner, emptyList()) }
    }
    Dispatchers.resetMain()
    unmockkAll()
  }

  @Test
  fun `review and send wait for metadata and validation of newly picked files`() = runTest(dispatcher) {
    val metadata = CompletableDeferred<List<Media>>()
    val validation = CompletableDeferred<MediaFilterResult>()
    coEvery { SystemMediaPicker.readMedia(application, listOf(second.uri), any()) } coAnswers { metadata.await() }
    coEvery { repository.validateAndFilterMedia(any(), any(), any()) } coAnswers { validation.await() }
    val sentRequest = slot<SendRequest>()
    coEvery { repository.send(capture(sentRequest)) } returns SendResult.Success
    val vm = createViewModel(listOf(first))

    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.MediaPicked(listOf(second.uri)))
    val send = async { vm.send() }
    runCurrent()
    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.NavigateToEdit)
    assertEquals(MediaSendNavKey.Select.Folders, vm.backStack.last())
    assertTrue(vm.isProcessingMedia.value)
    assertFalse(send.isCompleted)

    metadata.complete(listOf(second))
    runCurrent()
    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.NavigateToEdit)
    assertEquals(MediaSendNavKey.Select.Folders, vm.backStack.last())
    assertTrue(vm.isProcessingMedia.value)
    coVerify(exactly = 0) { repository.send(any()) }

    validation.complete(MediaFilterResult(listOf(first, second), null))
    runCurrent()

    assertEquals(SendResult.Success, send.await())
    assertEquals(listOf(first, second), sentRequest.captured.selectedMedia)
    assertFalse(vm.isProcessingMedia.value)
    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.NavigateToEdit)
    assertEquals(MediaSendNavKey.Edit, vm.backStack.last())
  }

  @Test
  fun `validation failures unblock the screen and release newly rejected files`() = runTest(dispatcher) {
    coEvery { SystemMediaPicker.readMedia(application, listOf(second.uri), any()) } returns listOf(second)
    coEvery { repository.validateAndFilterMedia(any(), any(), any()) } throws IOException("Provider unavailable")
    val vm = createViewModel(listOf(first))

    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.MediaPicked(listOf(second.uri)))
    runCurrent()

    assertFalse(vm.isProcessingMedia.value)
    assertEquals(listOf(first), vm.state.value.selectedMedia)
    verify { SystemMediaPicker.releaseUnusedPermissions(application, vm, emptyList()) }
    vm.onMediaSelectScreenEvent(MediaSelectScreenEvent.NavigateToEdit)
    assertEquals(MediaSendNavKey.Edit, vm.backStack.last())
  }

  @Test
  fun `restored pending selection resumes loading and retains its access`() = runTest(dispatcher) {
    coEvery { SystemMediaPicker.readMedia(application, listOf(second.uri), any()) } returns listOf(second)
    coEvery { repository.validateAndFilterMedia(any(), any(), any()) } returns MediaFilterResult(listOf(first, second), null)
    val vm = createViewModel(listOf(first), pending = listOf(second.uri))

    assertTrue(vm.isProcessingMedia.value)
    runCurrent()

    assertFalse(vm.isProcessingMedia.value)
    assertEquals(listOf(first, second), vm.state.value.selectedMedia)
    verify { SystemMediaPicker.retainPermissions(application, vm, listOf(second.uri)) }
    verify { SystemMediaPicker.releaseUnusedPermissions(application, vm, listOf(second.uri)) }
  }

  private fun createViewModel(selected: List<Media>, pending: List<Uri> = emptyList()): MediaSendViewModel {
    val values = mutableMapOf<String, Any>(
      "media_send_vm_args" to MediaSendActivityContract.Args(),
      "media_send_vm_identity_changes_since" to 0L,
      "media_send_vm_state" to MediaSendState(selectedMedia = selected, focusedMedia = selected.firstOrNull())
    )
    if (pending.isNotEmpty()) {
      values["system_picker_uris"] = ArrayList(pending)
      values["system_picker_pending_uris"] = ArrayList(pending)
    }
    return MediaSendViewModel(SavedStateHandle(values), repository, preUploadController, emptyFlow()).also {
      viewModel = it
      store.put("picker", it)
    }
  }

  private fun video(name: String) = Media(
    Uri.parse("content://picker/$name"), "video/mp4", 0, 640, 480, 100, 2000,
    false, false, Media.ALL_MEDIA_BUCKET_ID, null, null, "$name.mp4"
  )
}
