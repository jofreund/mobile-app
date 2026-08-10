import org.jetbrains.kotlin.gradle.plugin.mpp.NativeBuildType
import org.jetbrains.kotlin.gradle.plugin.mpp.TestExecutable

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.kotlinSerialization)
}

kotlin {
    // expect/actual classes are still marked Beta (KT-61573) but the design is
    // stable and widely used across this codebase. Suppress the per-declaration
    // warnings rather than littering @OptIn annotations.
    compilerOptions {
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    listOf(
        iosArm64(),
        iosSimulatorArm64()
    ).forEach { iosTarget ->
        iosTarget.binaries.framework {
            // Renamed off "ComposeApp" once the module stopped containing any Compose. The
            // Gradle module is still `:composeApp`, and its directory still `composeApp/`, on
            // purpose: upstream paths all start there, so renaming the directory would make
            // every future `git cherry-pick` from music-assistant/mobile-app a path-rewriting
            // exercise. The framework name costs nothing by comparison — no source path moves.
            baseName = "MusicAssistantKit"
            isStatic = true
            binaryOption("bundleId", "io.music_assistant.client.composeapp")
            // Trades a touch of release-link optimization for ~28% faster
            // linkReleaseFrameworkIosArm64 and a smaller binary. Experimental
            // Kotlin/Native flag — revisit if release-build correctness regresses.
            //
            // Release-only: `framework { }` configures both build types, and Kotlin/Native
            // ignores smallBinary in debug — warning about it on every single debug build.
            if (buildType == NativeBuildType.RELEASE) {
                binaryOption("smallBinary", "true")
            }
        }

        val webRtcSlice = if (iosTarget.name == "iosSimulatorArm64") {
            "ios-arm64_x86_64-simulator"
        } else {
            "ios-arm64"
        }
        iosTarget.binaries.withType<TestExecutable>().configureEach {
            linkerOpts("-F${project.rootDir}/iosApp/Frameworks/WebRTC.xcframework/$webRtcSlice")
        }

        val copyWebRtcForTests = tasks.register<Copy>("copyWebRtcFor${iosTarget.name.replaceFirstChar { it.uppercase() }}Tests") {
            description = "Copies the WebRTC framework slice for ${iosTarget.name} into the test build dir so the simulator can load it."
            from("${project.rootDir}/iosApp/Frameworks/WebRTC.xcframework/$webRtcSlice/WebRTC.framework")
            into(layout.buildDirectory.dir("bin/${iosTarget.name}/debugTest/Frameworks/WebRTC.framework"))
        }
        tasks.matching { it.name == "${iosTarget.name}Test" }.configureEach {
            dependsOn(copyWebRtcForTests)
        }
    }

    sourceSets {
        commonMain.dependencies {
            // Not a Compose dependency despite the package name — `SchemaVersionWarningViewModel`
            // extends `ViewModel` for its `viewModelScope`. The Compose-facing companion
            // (`lifecycle-runtime-compose`) is gone with everything else.
            implementation(libs.androidx.lifecycle.viewmodel)

            implementation(libs.ktor.client.core)
            implementation(libs.ktor.client.websockets)
            implementation(libs.ktor.client.json)
//            implementation(libs.ktor.client.logging)
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.atomicfu)

            api(libs.koin.core)

            implementation(libs.settings.multiplatform)

            implementation(libs.kermit)

            // WebRTC for remote access.
            // Phase A spike: switched from `com.shepeliev:webrtc-kmp` to Ktor EAP.
            // See plans/let-s-investigate-possible-migration-sequential-pike.md.
            implementation(libs.ktor.client.webrtc)
        }

        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.kotlinx.coroutines.test)
            implementation(libs.turbine)
            implementation(libs.settings.multiplatform.test)
        }

        iosMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
    }
}

// The MDI webfont task used to live here. It fetched the Material Design Icons community pack
// and projected its meta.json into a slim { name -> codepoint } table, so `MdiIcon.kt` could
// render the server's icon identifiers (e.g. "mdi-speaker") as font glyphs rather than hand-map
// each one to a look-alike from another pack.
//
// Both its consumer and its delivery mechanism are gone: `MdiIcon` went out with the dead Compose
// UI, and compose-resources — which is what turned `composeResources/font/**` into anything at
// all — is no longer a dependency. A network-bound task feeding a resource system that does not
// exist is worse than no task, so it's removed.
//
// The generated assets went too, in `ac16fa52`, along with the rest of the provider-icon chain —
// as did `composeResources/values*/strings.xml`, the source the `.xcstrings` catalog was
// exported from. Nothing under `composeResources/` is tracked any more; anything still on disk
// there is stale build output.
//
// If provider icons are ever revived, the font is what a native renderer would want, added to
// the Xcode target via `UIAppFonts` — that was the original Phase D plan. Recover both files
// with `git show 213f695a:composeApp/src/commonMain/composeResources/font/mdi_webfont.ttf` and
// the sibling `files/mdi_codepoints.json`. Re-deriving the codepoint table from upstream is the
// expensive half, and that is exactly what the file preserves.
