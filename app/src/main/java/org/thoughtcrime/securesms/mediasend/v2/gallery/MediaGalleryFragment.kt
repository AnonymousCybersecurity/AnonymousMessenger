package org.thoughtcrime.securesms.mediasend.v2.gallery

import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.core.content.ContextCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updateLayoutParams
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.RecyclerView
import kotlinx.coroutines.launch
import org.signal.core.models.media.Media
import org.signal.core.util.concurrent.SignalExecutors
import org.signal.mediasend.MediaSendDependencies
import org.signal.mediasend.select.SystemMediaPicker
import org.signal.mediasend.select.SystemMediaPickerContract
import org.thoughtcrime.securesms.R
import org.thoughtcrime.securesms.components.recyclerview.GridDividerDecoration
import org.thoughtcrime.securesms.databinding.V2MediaGalleryFragmentBinding
import org.thoughtcrime.securesms.util.RemoteConfig
import org.thoughtcrime.securesms.util.SystemWindowInsetsSetter
import org.thoughtcrime.securesms.util.ViewUtil
import org.thoughtcrime.securesms.util.adapter.mapping.MappingAdapter
import org.thoughtcrime.securesms.util.fragments.requireListener
import org.thoughtcrime.securesms.util.visible
import org.signal.core.ui.R as CoreUiR
import org.signal.mediasend.R as MediaSendR

/**
 * Selects media through Android's picker and displays only the user's selected files.
 */
class MediaGalleryFragment : Fragment(R.layout.v2_media_gallery_fragment) {

  private val viewModel: MediaPickerViewModel by activityViewModels()
  val isReading: Boolean get() = viewModel.isReading.value == true
  private lateinit var callbacks: Callbacks
  private var selectedMediaTouchHelper: ItemTouchHelper? = null
  private var hasLaunchedPicker = false
  private val selectedAdapter = MappingAdapter()
  private val galleryAdapter = MappingAdapter()
  private val viewStateLiveData = MutableLiveData<ViewState>()

  private val singlePicker = registerForActivityResult(SystemMediaPickerContract(1)) { uris ->
    onPickerResult(uris)
  }

  private val multiplePicker = registerForActivityResult(SystemMediaPickerContract(RemoteConfig.maxAttachmentCount.coerceAtLeast(2))) { uris ->
    onPickerResult(uris)
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    hasLaunchedPicker = savedInstanceState?.getBoolean(KEY_PICKER_LAUNCHED) ?: false
  }

  override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    callbacks = requireListener()
    if (viewStateLiveData.value == null) {
      viewStateLiveData.value = ViewState(chatColor = ContextCompat.getColor(requireContext(), CoreUiR.color.signal_light_colorPrimary))
    }
    val binding = V2MediaGalleryFragmentBinding.bind(view)
    SystemWindowInsetsSetter.attach(view, viewLifecycleOwner, WindowInsetsCompat.Type.navigationBars())
    binding.mediaGalleryToolbar.updateLayoutParams<ConstraintLayout.LayoutParams> {
      topMargin = ViewUtil.getStatusBarHeight(view)
    }
    binding.mediaGalleryStatusBarBackground.updateLayoutParams {
      height = ViewUtil.getStatusBarHeight(view)
    }
    binding.mediaGalleryToolbar.setNavigationOnClickListener { onBack() }
    binding.mediaGalleryToolbar.menu.findItem(R.id.action_camera).isVisible = callbacks.isCameraEnabled()
    binding.mediaGalleryToolbar.setOnMenuItemClickListener { item ->
      if (item.itemId == R.id.action_camera) {
        if (!isReading) callbacks.onNavigateToCamera()
        true
      } else {
        false
      }
    }

    binding.mediaGalleryManageButton.setOnClickListener { launchPicker() }
    binding.mediaGalleryAllowAccess.setOnClickListener { launchPicker() }
    binding.mediaGalleryCountButton.setOnClickListener { if (!isReading) callbacks.onSubmit() }
    binding.mediaGalleryGrid.layoutManager = GridLayoutManager(requireContext(), 4)
    binding.mediaGalleryGrid.addItemDecoration(GridDividerDecoration(4, ViewUtil.dpToPx(2)))
    MediaGallerySelectableItem.registerAdapter(
      mappingAdapter = galleryAdapter,
      onMediaClicked = { media, _ -> if (!isReading) callbacks.onMediaUnselected(media) },
      callbacks.isMultiselectEnabled()
    )
    binding.mediaGalleryGrid.adapter = galleryAdapter
    MediaGallerySelectedItem.register(selectedAdapter) { if (!isReading) callbacks.onSelectedMediaClicked(it) }
    binding.mediaGallerySelected.adapter = selectedAdapter
    selectedMediaTouchHelper?.attachToRecyclerView(binding.mediaGallerySelected)

    viewStateLiveData.observe(viewLifecycleOwner) { state ->
      binding.mediaGalleryBottomBarGroup.visible = state.selectedMedia.isNotEmpty()
      binding.mediaGalleryCountButton.setCount(state.selectedMedia.size)
      binding.mediaGalleryCountButton.setChatColor(state.chatColor)
      binding.mediaGalleryManageContainer.visible = state.selectedMedia.isNotEmpty()
      binding.mediaGalleryMissingPermissions.visible = state.selectedMedia.isEmpty()
      galleryAdapter.submitList(state.selectedMedia.mapIndexed { index, media ->
        MediaGallerySelectableItem.FileModel(media, true, index + 1, state.chatColor)
      })
      selectedAdapter.submitList(state.selectedMedia.map { MediaGallerySelectedItem.Model(it) })
    }

    val busyBackCallback = object : OnBackPressedCallback(false) {
      override fun handleOnBackPressed() = Unit
    }
    requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, busyBackCallback)
    viewModel.isReading.observe(viewLifecycleOwner) { isReading ->
      binding.mediaGalleryManageButton.isEnabled = !isReading
      binding.mediaGalleryAllowAccess.isEnabled = !isReading
      binding.mediaGalleryCountButton.isEnabled = !isReading
      binding.mediaGalleryLoading.visible = isReading
      busyBackCallback.isEnabled = isReading
    }
    viewModel.result.observe(viewLifecycleOwner) { result ->
      if (result != null) {
        viewModel.result.value = null
        if (result.hasUnreadableMedia) {
          Toast.makeText(requireContext(), MediaSendR.string.SystemMediaPicker__unable_to_read_media, Toast.LENGTH_LONG).show()
        }
        if (callbacks.isMultiselectEnabled()) {
          val selectedUris = viewStateLiveData.value?.selectedMedia?.map { it.uri }.orEmpty().toSet()
          val newMedia = result.media.filterNot { it.uri in selectedUris }.toSet()
          if (newMedia.isNotEmpty()) {
            // Keep review navigation blocked until the parent's validation has finished.
            callbacks.onMediaSelected(newMedia) { retainedUris -> viewModel.completeReading(retainedUris) }
          } else {
            viewModel.completeReading(selectedUris)
          }
        } else {
          result.media.firstOrNull()?.let { callbacks.onMediaSelected(it) }
          viewModel.completeReading()
        }
      }
    }

    if (!hasLaunchedPicker) {
      view.post {
        if (isAdded && this.view === view) {
          hasLaunchedPicker = true
          launchPicker()
        }
      }
    }
  }

  override fun onSaveInstanceState(outState: Bundle) {
    outState.putBoolean(KEY_PICKER_LAUNCHED, hasLaunchedPicker)
    super.onSaveInstanceState(outState)
  }

  private fun launchPicker() {
    if (viewModel.isReading.value == true) return
    try {
      if (callbacks.isMultiselectEnabled()) {
        multiplePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
      } else {
        singlePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
      }
    } catch (e: ActivityNotFoundException) {
      Toast.makeText(requireContext(), R.string.AttachmentManager_cant_open_media_selection, Toast.LENGTH_LONG).show()
    }
  }

  private fun onPickerResult(uris: List<Uri>) {
    if (uris.isEmpty()) {
      if (viewStateLiveData.value?.selectedMedia.isNullOrEmpty()) onBack()
    } else {
      val selectedUris = viewStateLiveData.value?.selectedMedia?.map { it.uri }.orEmpty()
      val newUris = if (callbacks.isMultiselectEnabled()) uris.filterNot { it in selectedUris } else uris
      if (newUris.isNotEmpty()) viewModel.readMedia(requireContext(), newUris)
    }
  }

  fun onBack() {
    if (!isReading) callbacks.onToolbarNavigationClicked()
  }

  fun onViewStateUpdated(state: ViewState) {
    if (!isReading) viewModel.retainOnly(state.selectedMedia.map { it.uri })
    viewStateLiveData.value = state
  }

  fun onMediaErrorOccurred() = Unit

  fun bindSelectedMediaItemDragHelper(helper: ItemTouchHelper) {
    selectedMediaTouchHelper = helper
    view?.findViewById<RecyclerView>(R.id.media_gallery_selected)?.let { helper.attachToRecyclerView(it) }
  }

  data class ViewState(
    val selectedMedia: List<Media> = listOf(),
    val chatColor: Int
  )

  interface Callbacks {
    fun isCameraEnabled(): Boolean = true
    fun isMultiselectEnabled(): Boolean = false
    fun onMediaSelected(media: Media)
    fun onMediaSelected(media: Set<Media>) = Unit
    fun onMediaSelected(media: Set<Media>, onComplete: (Set<Uri>) -> Unit) {
      onMediaSelected(media)
      onComplete(media.map { it.uri }.toSet())
    }
    fun onMediaUnselected(media: Set<Media>) = Unit
    fun onMediaUnselected(media: Media): Unit = throw UnsupportedOperationException()
    fun onSelectedMediaClicked(media: Media): Unit = throw UnsupportedOperationException()
    fun onNavigateToCamera(): Unit = throw UnsupportedOperationException()
    fun onSubmit(): Unit = throw UnsupportedOperationException()
    fun onToolbarNavigationClicked(): Unit = throw UnsupportedOperationException()
  }

  companion object {
    private const val KEY_PICKER_LAUNCHED = "system_picker_launched"
  }
}

/** Keeps a pending picker result across rotation while its metadata is being loaded. */
class MediaPickerViewModel(private val savedStateHandle: SavedStateHandle) : ViewModel() {
  val isReading = MutableLiveData(false)
  val result = MutableLiveData<Result?>()
  private var cleared = false

  init {
    SystemMediaPicker.retainPermissions(MediaSendDependencies.application, this, pickedUris())
    savedStateHandle.get<ArrayList<Uri>>(KEY_PENDING_URIS)?.let { readMedia(MediaSendDependencies.application, it) }
  }

  private fun pickedUris(): List<Uri> = savedStateHandle.get<ArrayList<Uri>>(KEY_PICKED_URIS).orEmpty()

  fun readMedia(context: Context, uris: List<Uri>) {
    if (isReading.value == true) return
    val applicationContext = context.applicationContext
    savedStateHandle[KEY_PICKED_URIS] = ArrayList((pickedUris() + uris).distinct())
    savedStateHandle[KEY_PENDING_URIS] = ArrayList(uris)
    isReading.value = true
    viewModelScope.launch {
      var delivered = false
      try {
        val media = SystemMediaPicker.readMedia(applicationContext, uris, this@MediaPickerViewModel)
        val unreadableUris = uris.toSet() - media.map { it.uri }.toSet()
        savedStateHandle[KEY_PICKED_URIS] = ArrayList(pickedUris().filterNot { it in unreadableUris })
        delivered = true
        result.value = Result(media, media.size != uris.distinct().size)
      } finally {
        if (!delivered) completeReading()
        if (cleared) SystemMediaPicker.releaseUnusedPermissions(applicationContext, this@MediaPickerViewModel)
      }
    }
  }

  fun retainOnly(uris: Collection<Uri>) {
    val retained = pickedUris().filter { it in uris }
    savedStateHandle[KEY_PICKED_URIS] = ArrayList(retained)
    SystemMediaPicker.releaseUnusedPermissions(MediaSendDependencies.application, this, retained)
  }

  fun completeReading(retainedUris: Collection<Uri>? = null) {
    if (retainedUris != null) retainOnly(retainedUris)
    savedStateHandle.remove<ArrayList<Uri>>(KEY_PENDING_URIS)
    isReading.value = false
  }

  override fun onCleared() {
    cleared = true
    SignalExecutors.BOUNDED_IO.execute { SystemMediaPicker.releaseUnusedPermissions(MediaSendDependencies.application, this) }
  }

  data class Result(val media: List<Media>, val hasUnreadableMedia: Boolean)

  companion object {
    private const val KEY_PICKED_URIS = "system_picker_uris"
    private const val KEY_PENDING_URIS = "system_picker_pending_uris"
  }
}
