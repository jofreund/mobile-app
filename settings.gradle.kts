rootProject.name = "MusicAssistantClient"

pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

include(":composeApp")

// Upstream's Sendspin player library, built from source (see sendspin-kmp/UPSTREAM).
include(":sendspin-kmp")