package org.thoughtcrime.securesms.keyvalue

import im.molly.unifiedpush.model.AnonymousSocketDevice
import im.molly.unifiedpush.model.RegistrationStatus
import org.signal.core.util.logging.Log

class UnifiedPushValues(store: KeyValueStore) : SignalStoreValues(store) {

  companion object {
    private val TAG = Log.tag(UnifiedPushValues::class)

    private const val ANONYMOUSSOCKET_DEVICE_ID = "anonymoussocket.deviceId"
    private const val ANONYMOUSSOCKET_PASSWORD = "anonymoussocket.passwd"
    private const val ANONYMOUSSOCKET_STATUS = "anonymoussocket.status"
    private const val ANONYMOUSSOCKET_AIR_GAPPED = "anonymoussocket.airGapped"
    private const val ANONYMOUSSOCKET_URL = "anonymoussocket.url"
    private const val ANONYMOUSSOCKET_VAPID = "anonymoussocket.vapid"
    private const val ANONYMOUSSOCKET_VAPID_SYNCED = "anonymoussocket.vapid.synced"
    private const val UNIFIEDPUSH_ENABLED = "up.enabled"
    private const val UNIFIEDPUSH_ENDPOINT = "up.endpoint"
    private const val UNIFIEDPUSH_LAST_RECEIVED_TIME = "up.lastRecvTime"
  }

  public override fun onFirstEverAppLaunch() = Unit

  public override fun getKeysToIncludeInBackup() = emptyList<String>()

  @get:JvmName("isEnabled")
  var enabled: Boolean by booleanValue(UNIFIEDPUSH_ENABLED, false)

  var device: AnonymousSocketDevice?
    get() {
      return AnonymousSocketDevice(
        deviceId = getInteger(ANONYMOUSSOCKET_DEVICE_ID, 0),
        password = getString(ANONYMOUSSOCKET_PASSWORD, null) ?: return null,
      )
    }
    set(device) {
      store.beginWrite()
        .putInteger(ANONYMOUSSOCKET_DEVICE_ID, device?.deviceId ?: 0)
        .putString(ANONYMOUSSOCKET_PASSWORD, device?.password)
        .apply()
    }

  fun isAnonymousSocketDevice(deviceId: Int): Boolean =
    deviceId != 0 && getInteger(ANONYMOUSSOCKET_DEVICE_ID, 0) == deviceId

  var registrationStatus: RegistrationStatus
    get() = RegistrationStatus.fromValue(getInteger(ANONYMOUSSOCKET_STATUS, -1)) ?: RegistrationStatus.UNKNOWN
    set(status) {
      putInteger(ANONYMOUSSOCKET_STATUS, status.value)
    }

  var endpoint: String? by stringValue(UNIFIEDPUSH_ENDPOINT, null)

  var airGapped: Boolean by booleanValue(ANONYMOUSSOCKET_AIR_GAPPED, false)

  var anonymousSocketUrl: String? by stringValue(ANONYMOUSSOCKET_URL, null)

  var vapidPublicKey:  String? by stringValue(ANONYMOUSSOCKET_VAPID, null)

  var vapidKeySynced: Boolean by booleanValue(ANONYMOUSSOCKET_VAPID_SYNCED, true)

  var lastReceivedTime: Long by longValue(UNIFIEDPUSH_LAST_RECEIVED_TIME, 0)

  val isAvailableOrAirGapped: Boolean
    get() = enabled && registrationStatus == RegistrationStatus.REGISTERED
}
