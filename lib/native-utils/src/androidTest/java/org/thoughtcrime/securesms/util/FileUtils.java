package org.thoughtcrime.securesms.util;

import java.io.FileDescriptor;

// Test-only JNI declarations with the same names and signatures as the app's utilities.
public final class FileUtils {
  static {
    System.loadLibrary("native-utils");
  }

  public static native int getFileDescriptorOwner(FileDescriptor descriptor);
  public static native int createMemoryFileDescriptor(String name);
}
