package im.molly.native_utils;

import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.system.Os;
import android.system.OsConstants;

import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.thoughtcrime.securesms.service.WipeMemoryService;
import org.thoughtcrime.securesms.util.FileUtils;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

@RunWith(AndroidJUnit4.class)
public class NativeUtilsCompatibilityTest {
  @Test
  public void memoryWipingUsesTheDevicePageSize() {
    assertEquals(Os.sysconf(OsConstants._SC_PAGESIZE), WipeMemoryService.getPageSize());
    assertEquals(0L, WipeMemoryService.allocPages(0));
    long pointer = WipeMemoryService.allocPages(3);
    assertNotEquals(0L, pointer);
    try {
      for (int index = 0; index < 3; index++) {
        WipeMemoryService.wipePage(pointer, index);
      }
    } finally {
      WipeMemoryService.freePages(pointer);
    }
  }

  @Test
  public void memoryFileDescriptorHasTheExpectedOwner() throws Exception {
    int descriptor = FileUtils.createMemoryFileDescriptor("native-utils-compatibility-test");
    assertTrue(descriptor >= 0);
    try (ParcelFileDescriptor file = ParcelFileDescriptor.adoptFd(descriptor)) {
      assertEquals(Process.myUid(), FileUtils.getFileDescriptorOwner(file.getFileDescriptor()));
    }
  }
}
