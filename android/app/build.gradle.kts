import org.gradle.api.tasks.Exec
import org.gradle.api.tasks.TaskProvider
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "de.circledev.fluxnews.nativeapp"
    compileSdk = 37
    defaultConfig { applicationId = "de.circle_dev.flux_news"; minSdk = 29; targetSdk = 37; versionCode = 1; versionName = "0.1.0"; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    buildTypes {
        debug { isMinifyEnabled = false }
        release { isMinifyEnabled = false; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
        create("migrationProbe") { initWith(getByName("debug")); isDebuggable = true; isMinifyEnabled = false; applicationIdSuffix = "" }
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("development") { dimension = "distribution"; applicationIdSuffix = ".native.dev"; versionNameSuffix = "-native-dev" }
        create("production") { dimension = "distribution" }
    }
    sourceSets {
        getByName("debug").kotlin.srcDir("../Build/Products/Bindings/debug/kotlin"); getByName("debug").jniLibs.srcDir("../Build/Products/debug")
        getByName("release").kotlin.srcDir("../Build/Products/Bindings/release/kotlin"); getByName("release").jniLibs.srcDir("../Build/Products/release")
        getByName("migrationProbe").java.srcDir("src/migrationProbe/java"); getByName("migrationProbe").kotlin.srcDir("../Build/Products/Bindings/debug/kotlin"); getByName("migrationProbe").jniLibs.srcDir("../Build/Products/debug")
    }
    buildFeatures { buildConfig = true; compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}

androidComponents {
    beforeVariants { variantBuilder ->
        val flavor = variantBuilder.productFlavors.singleOrNull { it.first == "distribution" }?.second
        if ((flavor == "production" && variantBuilder.buildType == "debug") || (flavor == "development" && variantBuilder.buildType == "release")) variantBuilder.enable = false
    }
}

val uniffiBuildScript = file("../Build/build-uniffi.sh")
fun registerUniffiPreparation(variantName: String, mode: String): TaskProvider<Exec> = tasks.register<Exec>("prepare${variantName.replaceFirstChar { it.uppercase() }}Uniffi") { inputs.file(uniffiBuildScript); inputs.file(file("../../core/crates/flux-uniffi/uniffi.toml")); outputs.dir(file("../Build/Products/$mode")); outputs.dir(file("../Build/Products/Bindings/$mode/kotlin")); commandLine(uniffiBuildScript.absolutePath, mode) }
fun wireUniffiPreparation(variantName: String, preparation: TaskProvider<Exec>) { val capitalized = variantName.replaceFirstChar { it.uppercase() }; tasks.matching { it.name == "compile${capitalized}Kotlin" || it.name == "merge${capitalized}JniLibFolders" || it.name == "merge${capitalized}NativeLibs" }.configureEach { dependsOn(preparation) } }
wireUniffiPreparation("developmentDebug", registerUniffiPreparation("developmentDebug", "debug"))
wireUniffiPreparation("productionMigrationProbe", registerUniffiPreparation("productionMigrationProbe", "debug"))

val migrationSigningProperties = Properties().apply { val file = rootProject.file("migration-signing.properties"); if (file.exists()) file.inputStream().use(::load) }
android.buildTypes.named("migrationProbe") { if (migrationSigningProperties.isNotEmpty()) signingConfig = android.signingConfigs.maybeCreate("migrationProbe").apply { keyAlias = migrationSigningProperties.getProperty("keyAlias"); keyPassword = migrationSigningProperties.getProperty("keyPassword"); storeFile = migrationSigningProperties.getProperty("storeFile")?.let(::file); storePassword = migrationSigningProperties.getProperty("storePassword") } }
val migrationVersionCode = providers.gradleProperty("fluxMigrationVersionCode").map(String::toInt).orElse(1)
androidComponents.onVariants(androidComponents.selector().withBuildType("migrationProbe")) { variant -> variant.outputs.forEach { output -> output.versionCode.set(migrationVersionCode) } }
tasks.matching { it.name == "testProductionMigrationProbeUnitTest" }.configureEach { (this as org.gradle.api.tasks.testing.Test).exclude("**/DevelopmentIdentityTest.class") }
wireUniffiPreparation("productionRelease", registerUniffiPreparation("productionRelease", "release"))


dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.navigation:navigation-compose:2.10.2")
    implementation("androidx.datastore:datastore-preferences:1.2.1")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation("androidx.compose.material3:material3")
    implementation("io.coil-kt.coil3:coil-compose:3.6.3")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.3")
    implementation("com.google.android.material:material:1.14.0")
    implementation("net.java.dev.jna:jna:5.19.1@aar")
    implementation("rustls:rustls-platform-verifier:${rootProject.extra["rustlsPlatformVerifierVersion"]}@aar")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260814")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core-ktx:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
}
