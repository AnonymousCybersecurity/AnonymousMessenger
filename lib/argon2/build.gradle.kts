plugins {
  id("com.android.library")
}

android {
  namespace = "org.signal.argon2"
  buildToolsVersion = libs.versions.buildTools.get()
  compileSdkVersion(libs.versions.compileSdk.get())
  ndkVersion = libs.versions.ndk.get()

  defaultConfig {
    minSdk = libs.versions.minSdk.get().toInt()
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    ndk {
      abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
    }
  }

  externalNativeBuild {
    ndkBuild {
      path = file("src/main/cpp/Android.mk")
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.toVersion(libs.versions.javaVersion.get())
    targetCompatibility = JavaVersion.toVersion(libs.versions.javaVersion.get())
  }
}

dependencies {
  androidTestImplementation(testLibs.junit.junit)
  androidTestImplementation(testLibs.androidx.test.runner)
  androidTestImplementation(testLibs.androidx.test.ext.junit)
}
