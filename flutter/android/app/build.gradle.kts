import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Подпись релиза — тот же ключ, что у нативного синхронизатора (android/keystore.properties),
// чтобы APK вставал поверх уже установленного приложения (тот же applicationId + та же подпись).
val keystoreProperties = Properties().apply {
    val f = file("../../../android/keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    // namespace = пакет Kotlin-классов (совпадает с MainActivity); applicationId ниже — это id
    // приложения, и он должен оставаться ru.cloudly.sync, чтобы вставать поверх старого клиента.
    namespace = "ru.cloudly.cloudly_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ru.cloudly.sync"
        // Тот же уровень, что у нативного клиента: обновление поверх него не требует понижения API.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        val storeFilePath = keystoreProperties.getProperty("storeFile")
        if (storeFilePath != null) {
            create("release") {
                storeFile = if (storeFilePath.startsWith("~/")) {
                    file(System.getProperty("user.home") + storeFilePath.substring(1))
                } else {
                    file(storeFilePath)
                }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
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
