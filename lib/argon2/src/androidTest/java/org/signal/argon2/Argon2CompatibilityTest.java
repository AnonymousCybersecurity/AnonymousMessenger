package org.signal.argon2;

import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.nio.charset.StandardCharsets;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

@RunWith(AndroidJUnit4.class)
public class Argon2CompatibilityTest {
  @Test
  public void argon2idMatchesExistingHashAndPreservesInputs() throws Exception {
    // This known-answer vector comes from the pinned upstream Argon2 test suite.
    byte[] password = "password".getBytes(StandardCharsets.US_ASCII);
    byte[] salt = "somesalt".getBytes(StandardCharsets.US_ASCII);
    Argon2 argon2 = new Argon2.Builder(Version.V13)
        .type(Type.Argon2id).iterations(2).memoryCostKiB(256).parallelism(1).build();

    Argon2.Result result = argon2.hash(password, salt);

    assertEquals("9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe", result.getHashHex());
    assertEquals("$argon2id$v=19$m=256,t=2,p=1$c29tZXNhbHQ$nf65EOgLrQMR/uIPnA4rEsF5h7TKyQwu9U1bMCHGi/4", result.getEncoded());
    assertArrayEquals("password".getBytes(StandardCharsets.US_ASCII), password);
    assertArrayEquals("somesalt".getBytes(StandardCharsets.US_ASCII), salt);
    assertTrue(Argon2.verify(result.getEncoded(), password));
    assertFalse(Argon2.verify(result.getEncoded(), "wrong-password".getBytes(StandardCharsets.US_ASCII)));
  }

  @Test
  public void parallelArgon2idMatchesExistingHash() throws Exception {
    Argon2 argon2 = new Argon2.Builder(Version.V13)
        .type(Type.Argon2id).iterations(2).memoryCostKiB(256).parallelism(2).hashRaw(true).build();

    Argon2.Result result = argon2.hash(
        "password".getBytes(StandardCharsets.US_ASCII), "somesalt".getBytes(StandardCharsets.US_ASCII));

    assertEquals("6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037", result.getHashHex());
  }

  @Test
  public void legacyArgon2iHashStillVerifies() {
    assertTrue(Argon2.verify(
        "$argon2i$m=256,t=2,p=1$c29tZXNhbHQ$/U3YPXYsSb3q9XxHvc0MLxur+GP960kN9j7emXX8zwY",
        "password".getBytes(StandardCharsets.US_ASCII), Type.Argon2i));
  }
}
