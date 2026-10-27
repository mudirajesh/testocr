import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. android/key.properties holds storeFile, storePassword,
// keyAlias and keyPassword (see README.md). The file is git-ignored and must
// never be committed.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.barcode.gs1scan"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.barcode.gs1scan"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        // Uses the version code and name from pubspec.yaml (version: 1.0.0+1).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Signed with the release key when android/key.properties exists;
            // otherwise the DEBUG key is used so `flutter build` still works,
            // and a warning is printed (see the taskGraph hook below).
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 code shrinking + resource shrinking.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

// Loud warning when a release artifact is about to be built without the
// release key.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        val name = it.name
        name.contains("Release") &&
            (name.startsWith("assemble") || name.startsWith("bundle") || name.startsWith("package"))
    }
    if (buildsRelease && !hasReleaseKeystore) {
        logger.warn(
            "\n" +
                "************************************************************\n" +
                "WARNING: android/key.properties was not found.\n" +
                "This release build is signed with the DEBUG key. It is NOT\n" +
                "release-signed and must not be distributed. See README.md\n" +
                "(\"Release signing\") to create the keystore.\n" +
                "************************************************************\n"
        )
    }
}
