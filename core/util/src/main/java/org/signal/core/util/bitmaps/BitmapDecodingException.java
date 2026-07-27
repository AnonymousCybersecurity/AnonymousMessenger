/*
 * Copyright 2026 Anonymous Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.core.util.bitmaps;

public class BitmapDecodingException extends Exception {

  public BitmapDecodingException(String s) {
    super(s);
  }

  public BitmapDecodingException(Exception nested) {
    super(nested);
  }
}
