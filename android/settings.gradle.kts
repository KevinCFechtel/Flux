import groovy.json.JsonSlurper

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// The Android part of `rustls-platform-verifier` ships as a prebuilt AAR inside the
// `rustls-platform-verifier-android` crate that `core/Cargo.lock` already pins. Resolving it
// through `cargo metadata` keeps the Kotlin verifier component and the Rust crate on exactly
// the same version without a hand-copied source file or a floating Maven coordinate.
val platformVerifierComponent: Map<String, String> = run {
    val coreManifest = rootDir.resolve("../core/crates/flux-uniffi/Cargo.toml").canonicalFile
    val metadata = providers.exec {
        commandLine(
            "cargo",
            "metadata",
            "--format-version",
            "1",
            "--manifest-path",
            coreManifest.path,
        )
    }.standardOutput.asText.get()

    @Suppress("UNCHECKED_CAST")
    val packages = (JsonSlurper().parseText(metadata) as Map<String, Any>)["packages"]
        as List<Map<String, Any>>
    val component = packages.singleOrNull { it["name"] == "rustls-platform-verifier-android" }
        ?: error(
            "rustls-platform-verifier-android is not part of the Cargo dependency graph of " +
                coreManifest.path,
        )
    val repository = file(component["manifest_path"] as String).parentFile.resolve("maven")
    require(repository.isDirectory) {
        "The pinned rustls-platform-verifier Android component has no Maven repository at $repository"
    }
    mapOf("repository" to repository.path, "version" to component["version"] as String)
}

gradle.beforeProject {
    extra["rustlsPlatformVerifierVersion"] = platformVerifierComponent.getValue("version")
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            name = "rustlsPlatformVerifier"
            url = uri(platformVerifierComponent.getValue("repository"))
            metadataSources.artifact()
            content {
                includeGroup("rustls")
            }
        }
    }
}

rootProject.name = "FluxNewsNative"
include(":app")
