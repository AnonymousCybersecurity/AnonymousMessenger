package org.thoughtcrime.securesms.conversation;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.button.MaterialButton;

import org.signal.core.models.media.Media;
import org.signal.core.ui.util.ThemeUtil;
import org.thoughtcrime.securesms.R;
import org.thoughtcrime.securesms.components.InputAwareLayout;

import java.util.Arrays;
import java.util.List;
import java.util.function.Predicate;
import java.util.stream.Collectors;

public class AttachmentKeyboard extends FrameLayout implements InputAwareLayout.InputView {

  private static final List<AttachmentKeyboardButton> DEFAULT_BUTTONS = Arrays.asList(
      AttachmentKeyboardButton.GALLERY,
      AttachmentKeyboardButton.FILE,
      AttachmentKeyboardButton.POLL,
      AttachmentKeyboardButton.CONTACT,
      AttachmentKeyboardButton.LOCATION
  );

  private View container;
  private AttachmentKeyboardButtonAdapter buttonAdapter;
  private Callback callback;

  public AttachmentKeyboard(@NonNull Context context) {
    super(context);
    init(context);
  }

  public AttachmentKeyboard(@NonNull Context context, @Nullable AttributeSet attrs) {
    super(context, attrs);
    init(context);
  }

  private void init(@NonNull Context context) {
    inflate(context, R.layout.attachment_keyboard, this);
    container = findViewById(R.id.attachment_keyboard_container);

    RecyclerView buttonList = findViewById(R.id.attachment_keyboard_button_list);
    buttonList.setItemAnimator(null);
    buttonAdapter = new AttachmentKeyboardButtonAdapter(button -> {
      if (callback != null) callback.onAttachmentSelectorClicked(button);
    });
    buttonList.setAdapter(buttonAdapter);
    buttonAdapter.registerAdapterDataObserver(new AttachmentButtonCenterHelper(buttonList));
    buttonList.setLayoutManager(new LinearLayoutManager(context, LinearLayoutManager.HORIZONTAL, false));
    buttonAdapter.setButtons(DEFAULT_BUTTONS);

    // Open the system picker instead of querying the user's entire media library.
    findViewById(R.id.attachment_keyboard_media_list).setVisibility(GONE);
    findViewById(R.id.attachment_keyboard_manage_button).setVisibility(GONE);
    TextView pickerText = findViewById(R.id.attachment_keyboard_permission_text);
    pickerText.setText(org.signal.mediasend.R.string.SystemMediaPicker__only_selected_media);
    pickerText.setVisibility(VISIBLE);
    MaterialButton pickerButton = findViewById(R.id.attachment_keyboard_permission_button);
    pickerButton.setText(org.signal.mediasend.R.string.SystemMediaPicker__choose_photos_and_videos);
    pickerButton.setVisibility(VISIBLE);
    pickerButton.setOnClickListener(v -> {
      if (callback != null) callback.onAttachmentPickerRequested();
    });
  }

  public void setCallback(@NonNull Callback callback) {
    this.callback = callback;
  }

  public void filterAttachmentKeyboardButtons(@Nullable Predicate<AttachmentKeyboardButton> buttonPredicate) {
    buttonAdapter.setButtons(buttonPredicate == null ? DEFAULT_BUTTONS : DEFAULT_BUTTONS.stream().filter(buttonPredicate).collect(Collectors.toList()));
  }

  public void setWallpaperEnabled(boolean wallpaperEnabled) {
    container.setBackgroundColor(ThemeUtil.getThemedColor(getContext(), wallpaperEnabled ? R.color.wallpaper_compose_background : R.attr.signal_background_primary));
    buttonAdapter.setWallpaperEnabled(wallpaperEnabled);
  }

  @Override
  public void show(int height, boolean immediate) {
    ViewGroup.LayoutParams params = getLayoutParams();
    params.height = height;
    setLayoutParams(params);
    setVisibility(VISIBLE);
  }

  @Override
  public void hide(boolean immediate) {
    setVisibility(GONE);
  }

  @Override
  public boolean isShowing() {
    return getVisibility() == VISIBLE;
  }

  public interface Callback {
    void onAttachmentMediaClicked(@NonNull Media media);
    void onAttachmentSelectorClicked(@NonNull AttachmentKeyboardButton button);
    void onAttachmentPickerRequested();
  }
}
