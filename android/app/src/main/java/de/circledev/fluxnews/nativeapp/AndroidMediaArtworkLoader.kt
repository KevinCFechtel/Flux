package de.circledev.fluxnews.nativeapp

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

internal object AndroidMediaArtworkLoader {
    private const val MaxArtworkBytes = 10 * 1024 * 1024

    private val client = OkHttpClient.Builder()
        .fastFallback(true)
        .retryOnConnectionFailure(true)
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    suspend fun loadRemote(url: String): ByteArray? = withContext(Dispatchers.IO) {
        val parsed = url.toHttpUrlOrNull() ?: return@withContext null
        if (parsed.scheme != "http" && parsed.scheme != "https") {
            return@withContext null
        }

        val request = Request.Builder()
            .url(parsed)
            .header("Accept", "image/*")
            .build()

        runCatching {
            client.newCall(request).execute().use responseUse@{ response ->
                if (!response.isSuccessful) return@responseUse null
                val body = response.body
                val contentLength = body.contentLength()
                if (contentLength > MaxArtworkBytes.toLong()) return@responseUse null

                body.byteStream().use inputUse@{ input ->
                    val output = java.io.ByteArrayOutputStream(
                        if (contentLength in 1..MaxArtworkBytes.toLong()) {
                            contentLength.toInt()
                        } else {
                            64 * 1024
                        },
                    )
                    val buffer = ByteArray(32 * 1024)
                    var total = 0
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MaxArtworkBytes) return@inputUse null
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray().takeIf { it.isNotEmpty() }
                }
            }
        }.getOrNull()
    }
}
