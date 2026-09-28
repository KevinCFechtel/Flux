import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.gradle.api.tasks.Exec
import org.gradle.api.tasks.TaskProvider

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "de.circledev.fluxnews.nativeapp"
    compileSdk = 36

    defaultConfig {
        applicationId = "de.circle_dev.flux_news"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("development") {
            dimension = "distribution"
            applicationIdSuffix = ".native.dev"
            versionNameSuffix = "-native-dev"
        }
        create("production") {
            dimension = "distribution"
        }
    }

    sourceSets {
        getByName("debug").java.srcDir("../Build/Products/Bindings/debug/kotlin")
        getByName("debug").jniLibs.srcDir("../Build/Products/debug")
        getByName("release").java.srcDir("../Build/Products/Bindings/release/kotlin")
        getByName("release").jniLibs.srcDir("../Build/Products/release")
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

androidComponents {
    beforeVariants { variantBuilder ->
        val flavor = variantBuilder.productFlavors
            .singleOrNull { it.first == "distribution" }
            ?.second
        if ((flavor == "production" && variantBuilder.buildType == "debug") ||
            (flavor == "development" && variantBuilder.buildType == "release")) {
            variantBuilder.enable = false
        }
    }
}

val uniffiBuildScript = file("../Build/build-uniffi.sh")

fun registerUniffiPreparation(variantName: String, mode: String): TaskProvider<Exec> =
    tasks.register<Exec>("prepare${variantName.replaceFirstChar { it.uppercase() }}Uniffi") {
        inputs.file(uniffiBuildScript)
        inputs.file(file("../../core/crates/flux-uniffi/uniffi.toml"))
        outputs.dir(file("../Build/Products/$mode"))
        outputs.dir(file("../Build/Products/Bindings/$mode/kotlin"))
        commandLine(uniffiBuildScript.absolutePath, mode)
    }

fun wireUniffiPreparation(variantName: String, preparation: TaskProvider<Exec>) {
    val capitalized = variantName.replaceFirstChar { it.uppercase() }
    tasks.matching {
        it.name == "compile${capitalized}Kotlin" ||
            it.name == "merge${capitalized}JniLibFolders" ||
            it.name == "merge${capitalized}NativeLibs"
    }.configureEach {
        dependsOn(preparation)
    }
}

wireUniffiPreparation(
    "developmentDebug",
    registerUniffiPreparation("developmentDebug", "debug"),
)
wireUniffiPreparation(
    "productionRelease",
    registerUniffiPreparation("productionRelease", "release"),
)

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.02.00"))
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("com.google.android.material:material:1.12.0")
    implementation("net.java.dev.jna:jna:5.13.0@aar")

    testImplementation("junit:junit:4.13.2")
}
