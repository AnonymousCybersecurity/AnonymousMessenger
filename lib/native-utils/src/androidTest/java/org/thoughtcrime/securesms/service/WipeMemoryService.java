package org.thoughtcrime.securesms.service;

// Test-only JNI declarations with the same names and signatures as the app's service.
public final class WipeMemoryService {
  static {
    System.loadLibrary("native-utils");
  }

  public static native long allocPages(int count);
  public static native void freePages(long pointer);
  public static native void wipePage(long pointer, int index);
  public static native int getPageSize();
}
