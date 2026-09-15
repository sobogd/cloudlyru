import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Подпись релиза — ключ лежит рядом, в flutter/android/keystore.properties (в git не попадает;
// в CI его пишет workflow из секретов). Ключ обязан остаться тем же: приложение уже установлено
// на телефоне, и обновление поверх возможно только с той же подписью и тем же applicationId.
val keystoreProperties = Properties().apply {
    val f = file("../keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    // namespace = пакет Kotlin-классов (совпадает с MainActivity); applicationId ниже — это id
    // приложения, и он остаётся ru.cloudly.sync: смена id поставила бы рядом второе приложение.
    namespace = "ru.cloudly.cloudly_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ru.cloudly.sync"
        // 29 — уровень уже установленного приложения: обновление поверх него не требует понижения API.
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
