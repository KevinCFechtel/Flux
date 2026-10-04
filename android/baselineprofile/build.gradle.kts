plugins {
    id("com.android.test")
    id("androidx.baselineprofile")
}

android {
    namespace = "de.circledev.fluxnews.baselineprofile"
    compileSdk = 37

    defaultConfig {
        minSdk = 29
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        missingDimensionStrategy("distribution", "development")
    }

    targetProjectPath = ":app"

    buildTypes {
        create("benchmark") {
            isDebuggable = false
            signingConfig = debug.signingConfig
            matchingFallbacks += listOf("release")
        }
    }

    experimentalProperties["android.experimental.self-instrumenting"] = true
}

baselineProfile {
    useConnectedDevices = true
}

dependencies {
    implementation("androidx.test.ext:junit:1.3.0")
    implementation("androidx.test.uiautomator:uiautomator:2.4.0")
    implementation("androidx.benchmark:benchmark-macro-junit4:1.5.0")
}
