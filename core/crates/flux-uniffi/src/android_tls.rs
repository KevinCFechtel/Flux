//! Narrow Android TLS bootstrap.
//!
//! The pinned `rustls-platform-verifier` needs a JVM handle, an Android `Context` and the
//! application class loader before the first Rust TLS handshake, and it only offers a JNI
//! typed entry point for that. This module provides exactly that hook and nothing else: it
//! carries no domain data, no JSON, no Miniflux concepts and no Core operations. UniFFI
//! remains the only product API between Android and the Core.
//!
//! The Kotlin counterpart is `de.circledev.fluxnews.nativeapp.AndroidPlatformTrust`; the JNI
//! symbol below is derived from that fully qualified name, so the two must stay in sync.

use jni::JNIEnv;
use jni::objects::{JClass, JObject};

/// Initializes the Android platform certificate verifier used by the Core's HTTP transport.
///
/// `context` must be an application-scoped `android.content.Context`. The underlying
/// initialization is idempotent for the lifetime of the process: repeated calls keep the
/// first successfully stored JVM handles. A failure raises `IllegalStateException` so the
/// caller cannot silently continue into an unverified TLS path.
#[unsafe(no_mangle)]
pub extern "system" fn Java_de_circledev_fluxnews_nativeapp_AndroidPlatformTrust_nativeInitialize(
    mut env: JNIEnv,
    _class: JClass,
    context: JObject,
) {
    if let Err(error) = rustls_platform_verifier::android::init_with_env(&mut env, context) {
        let _ = env.throw_new(
            "java/lang/IllegalStateException",
            format!("Android TLS platform verifier initialization failed: {error}"),
        );
    }
}
