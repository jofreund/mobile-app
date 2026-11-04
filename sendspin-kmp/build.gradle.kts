import org.jetbrains.kotlin.gradle.dsl.KotlinVersion
import org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation

// The fork's build of upstream's `sendspin-kmp` module. Everything under src/, api/ and the
// module docs is upstream's, copied by scripts/sync-sendspin-kmp.sh (pinned commit in
// UPSTREAM). This file is the only part the fork owns: upstream's adds an Android target and
// Maven publishing, and this one keeps the two iOS targets the app ships.
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.kotlinSerialization)
}

// Same coordinates as upstream's publication, so the klib's unique name matches the ABI dump.
group = "io.github.music-assistant"

kotlin {
    explicitApi()

    // checkKotlinAbi compares the public API with upstream's committed dump in api/, so an
    // upstream sync that changes the API shows up here as well as in the changelog.
    @OptIn(ExperimentalAbiValidation::class)
    abiValidation()

    compilerOptions {
        languageVersion.set(KotlinVersion.KOTLIN_2_3)
        apiVersion.set(KotlinVersion.KOTLIN_2_3)
    }

    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        commonMain.dependencies {
            api(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.atomicfu)
            api(libs.ktor.client.core)
            implementation(libs.ktor.client.websockets)
            implementation(libs.ktor.client.json)
            implementation(libs.kermit)
            implementation(libs.cryptography.core)
        }

        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.kotlinx.coroutines.test)
            implementation(libs.turbine)
            implementation(libs.ktor.client.mock)
        }

        iosMain.dependencies {
            // Noise primitives backend (CryptoKit: X25519, ChaCha20-Poly1305).
            implementation(libs.cryptography.provider.cryptokit)
        }
    }
}
