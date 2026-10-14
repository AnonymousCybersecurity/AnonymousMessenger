LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := native-utils
LOCAL_C_INCLUDES := $(LOCAL_PATH)
LOCAL_CFLAGS += -Wall
# Keep the native ELF segments and RELRO compatible with 16 KB Android pages.
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
ifeq ($(APP_OPTIM),release)
LOCAL_LDFLAGS += -Wl,--build-id=none
endif

LOCAL_SRC_FILES := org_thoughtcrime_securesms_util_FileUtils.cpp \
                   org_thoughtcrime_securesms_service_WipeMemoryService.c

include $(BUILD_SHARED_LIBRARY)
