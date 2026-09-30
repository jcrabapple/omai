import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The keystore and its passwords live OUTSIDE the repo
// (default ~/.config/omai-signing/key.properties; override with
// OMAI_KEY_PROPERTIES). Without it, release builds fall back to the debug key
// and say so, so CI or a fresh clone can still build.
val keyPropertiesFile = file(
    System.getenv("OMAI_KEY_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.config/omai-signing/key.properties",
)
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) FileInputStream(keyPropertiesFile).use { load(it) }
}
val hasReleaseKey = keyProperties.getProperty("storeFile")?.let { file(it).exists() } == true

android {
    namespace = "us.snakepit.omai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "us.snakepit.omai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn("Omai: no release key at $keyPropertiesFile; signing release with the DEBUG key")
                signingConfig = signingConfigs.getByName("debug")
            }
        }
        debug {
            // Debug installs live beside the release app instead of fighting
            // it over the same package (different signing keys can't update
            // each other).
            // Label "Omai Debug" and debug-package shortcuts come from
            // src/debug/res.
            applicationIdSuffix = ".debug"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
