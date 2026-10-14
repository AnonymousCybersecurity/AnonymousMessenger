LOCAL_PATH := $(call my-dir)
ARGON2_DIR := $(LOCAL_PATH)/argon2

include $(CLEAR_VARS)

LOCAL_MODULE := argon2
LOCAL_C_INCLUDES := $(ARGON2_DIR)/include/
LOCAL_CFLAGS += -Wall
# Keep the native ELF segments and RELRO compatible with 16 KB Android pages.
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
ifeq ($(APP_OPTIM),release)
LOCAL_LDFLAGS += -Wl,--build-id=none
endif

LOCAL_SRC_FILES := org_signal_argon2_Argon2Native.c \
                   argon2/src/blake2/blake2b.c \
                   argon2/src/argon2.c \
                   argon2/src/core.c \
                   argon2/src/encoding.c \
                   argon2/src/genkat.c \
                   argon2/src/ref.c \
                   argon2/src/thread.c

include $(BUILD_SHARED_LIBRARY)
