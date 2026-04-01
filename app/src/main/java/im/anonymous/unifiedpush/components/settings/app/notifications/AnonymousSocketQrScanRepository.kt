package im.molly.unifiedpush.components.settings.app.notifications

import android.content.Context
import android.net.Uri
import com.bumptech.glide.Glide
import com.bumptech.glide.load.DecodeFormat
import im.molly.unifiedpush.AnonymousSocketRepository
import im.molly.unifiedpush.model.AnonymousSocket
import io.reactivex.rxjava3.core.Single
import io.reactivex.rxjava3.schedulers.Schedulers
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.signal.core.util.logging.Log
import org.signal.core.util.toOptional
import org.signal.qr.QrProcessor

/**
 * A collection of functions to help with scanning QR codes for AnonymousSocket.
 */
object AnonymousSocketQrScanRepository {
  private const val TAG = "AnonymousSocketQrScanRepository"

  /**
   * Resolves QR data to a AnonymousSocket link URI, coercing it to a standard set of [QrScanResult]s.
   */
  fun lookupQrLink(data: String): Single<QrScanResult> {
    val uri = Uri.parse(data)
    return when (val anonymousSocket = AnonymousSocket.parseLink(uri)) {
      is AnonymousSocket.AirGapped -> {
        Single.just(QrScanResult.Success(data))
      }

      is AnonymousSocket.WebServer -> {
        checkAnonymousSocketServer(anonymousSocket.url).map { found ->
          if (found) {
            QrScanResult.Success(data)
          } else {
            // TODO add network check
            QrScanResult.NotFound(anonymousSocket.url)
          }
        }.subscribeOn(Schedulers.io())
      }

      else -> Single.just(QrScanResult.InvalidData)
    }
  }

  private fun checkAnonymousSocketServer(url: String): Single<Boolean> {
    return Single
      .fromCallable {
        runCatching {
          AnonymousSocketRepository.discoverAnonymousSocketServer(url.toHttpUrl())
        }.getOrElse { e ->
          Log.e(TAG, "Cannot discover AnonymousSocket", e)
          false
        }
      }.subscribeOn(Schedulers.io())
  }

  fun scanImageUriForQrCode(context: Context, uri: Uri): Single<QrScanResult> {
    val loadBitmap = Glide.with(context)
      .asBitmap()
      .format(DecodeFormat.PREFER_ARGB_8888)
      .load(uri)
      .submit()

    return Single.fromFuture(loadBitmap)
      .map { QrProcessor().getScannedData(it).toOptional() }
      .flatMap {
        if (it.isPresent) {
          lookupQrLink(it.get())
        } else {
          Single.just(QrScanResult.QrNotFound)
        }
      }
      .subscribeOn(Schedulers.io())
  }
}
