# The Android component of rustls-platform-verifier is only ever reached from Rust through JNI,
# so R8 cannot see the usage and would otherwise treat it as dead code.
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }

# The TLS bootstrap entry point is bound by its fully qualified name from the Rust cdylib.
-keepclasseswithmembernames, includedescriptorclasses class de.circledev.fluxnews.nativeapp.AndroidPlatformTrust {
    native <methods>;
}
