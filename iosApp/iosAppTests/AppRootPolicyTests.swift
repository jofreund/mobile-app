import XCTest

/// Port of Kotlin's `AppRootRouterTest`, which guarded the policy while it lived in
/// `AppRootRouter`. Same cases, now over `RootSession` values: the splash latch, the
/// destination-forcing rules, the reconnection banner, plus the schema floor check that
/// `SchemaVersionWarningViewModel` used to own.
final class AppRootPolicyTests: XCTestCase {

    private func authenticated(wasAutoLogin: Bool = true) -> RootSession {
        .connected(.init(
            dataConnection: .authenticated,
            authProcess: .notStarted,
            wasAutoLogin: wasAutoLogin,
            hasSavedToken: true,
            minSupportedSchemaVersion: nil
        ))
    }

    private func awaitingAuth(
        _ authProcess: RootSession.AuthProcess = .notStarted,
        hasSavedToken: Bool = false
    ) -> RootSession {
        .connected(.init(
            dataConnection: .awaitingAuth,
            authProcess: authProcess,
            wasAutoLogin: false,
            hasSavedToken: hasSavedToken,
            minSupportedSchemaVersion: nil
        ))
    }

    private func policy(autoLogin: Bool, initial: RootSession = .disconnectedInitial) -> AppRootPolicy {
        AppRootPolicy(willAutoLoginOnLaunch: autoLogin, initial: initial)
    }

    // MARK: - Initial destination

    func testInitialDestinationIsSettingsWhenDisconnectedWithNoSavedToken() {
        XCTAssertEqual(policy(autoLogin: false).destination, .settings)
    }

    func testInitialDestinationIsMainWhenASavedTokenMeansAutoLoginWillRun() {
        XCTAssertEqual(policy(autoLogin: true).destination, .main)
    }

    func testInitialDestinationIsMainWhenAlreadyAuthenticatedAtConstruction() {
        XCTAssertEqual(policy(autoLogin: false, initial: authenticated()).destination, .main)
    }

    // MARK: - Splash

    func testSplashIsNotVisibleWithoutASavedTokenToAutoLoginWith() {
        XCTAssertFalse(policy(autoLogin: false).splashVisible)
    }

    func testSplashIsVisibleWhileAutoLoginIsInFlight() {
        var sut = policy(autoLogin: true)
        XCTAssertTrue(sut.splashVisible, "Precondition: splash up during Disconnected.Initial")

        sut.apply(.connecting)
        XCTAssertTrue(sut.splashVisible)

        sut.apply(awaitingAuth())
        XCTAssertTrue(sut.splashVisible, "Still awaiting auth resolution")
    }

    func testSplashDismissesOnSuccessfulAuthAndNeverReappears() {
        var sut = policy(autoLogin: true)

        sut.apply(authenticated())
        XCTAssertFalse(sut.splashVisible)

        // A later user-initiated reconnect revisits a splash-shaped state — the latch must
        // keep it hidden.
        sut.apply(.connecting)
        XCTAssertFalse(sut.splashVisible, "Latch must survive a later reconnect attempt")
    }

    func testSplashDismissesOnAuthFailureAndNeverReappears() {
        var sut = policy(autoLogin: true)

        sut.apply(awaitingAuth(.failed))
        XCTAssertFalse(sut.splashVisible)

        sut.apply(.connecting)
        XCTAssertFalse(sut.splashVisible, "Latch must survive a later reconnect attempt")
    }

    func testCancelAutoLoginHidesTheSplashImmediatelyAndForGood() {
        var sut = policy(autoLogin: true)
        XCTAssertTrue(sut.splashVisible)

        sut.cancelAutoLogin()
        XCTAssertFalse(sut.splashVisible)

        sut.apply(.connecting)
        XCTAssertFalse(sut.splashVisible, "Cancel must latch, not just hide")
    }

    // MARK: - Destination switching

    func testDestinationIsPreservedDuringReconnecting() {
        var sut = policy(autoLogin: false, initial: authenticated())
        XCTAssertEqual(sut.destination, .main)

        sut.apply(.reconnecting(attempt: 1, isOnline: true, minSupportedSchemaVersion: nil))
        XCTAssertEqual(sut.destination, .main)
    }

    func testDestinationIsPreservedWhileBackgrounded() {
        var sut = policy(autoLogin: false, initial: authenticated())

        sut.apply(.disconnectedBackgrounded)
        XCTAssertEqual(sut.destination, .main)
    }

    func testDestinationForcesSettingsOnATerminalDisconnect() {
        var sut = policy(autoLogin: false, initial: authenticated())

        sut.apply(.disconnectedResolved)
        XCTAssertEqual(sut.destination, .settings)
    }

    func testDestinationForcesMainWhenAutoLoginSucceeds() {
        var sut = policy(autoLogin: true)
        XCTAssertEqual(sut.destination, .main, "Biased to Main pre-resolution")

        sut.apply(authenticated(wasAutoLogin: true))
        XCTAssertEqual(sut.destination, .main)
    }

    func testAuthenticatingWithoutWasAutoLoginDoesNotForceAScreenChange() {
        var sut = policy(autoLogin: false)
        sut.requestSettings()
        XCTAssertEqual(sut.destination, .settings)

        // A manual (non-auto) login succeeding shouldn't yank the user off the Settings screen
        // they're sitting on — Settings itself navigates home once its own UI decides to.
        sut.apply(authenticated(wasAutoLogin: false))
        XCTAssertEqual(sut.destination, .settings)
    }

    func testDestinationForcesSettingsWhenAuthIsRejected() {
        var sut = policy(autoLogin: false, initial: authenticated())

        sut.apply(awaitingAuth(.failed))
        XCTAssertEqual(sut.destination, .settings)
    }

    func testDestinationForcesSettingsWhenConnectedWithNoSavedTokenToAutoLoginWith() {
        // Revoked-token dead end: the server rejected the token once, AuthenticationManager
        // cleared it, and every later connect parks in AwaitingAuth(NotStarted) forever.
        var sut = policy(autoLogin: false, initial: .connecting)
        sut.requestHome()
        XCTAssertEqual(sut.destination, .main)

        sut.apply(awaitingAuth(.notStarted, hasSavedToken: false))
        XCTAssertEqual(sut.destination, .settings)
    }

    func testDestinationIsPreservedInAwaitingAuthWhenASavedTokenMeansAutoLoginWillRun() {
        var sut = policy(autoLogin: true, initial: authenticated())

        sut.apply(awaitingAuth(.notStarted, hasSavedToken: true))
        XCTAssertEqual(sut.destination, .main)
    }

    func testRequestSettingsAndRequestHomeOverrideImmediatelyRegardlessOfSessionState() {
        var sut = policy(autoLogin: false, initial: authenticated())
        XCTAssertEqual(sut.destination, .main)

        sut.requestSettings()
        XCTAssertEqual(sut.destination, .settings)

        sut.requestHome()
        XCTAssertEqual(sut.destination, .main)
    }

    // MARK: - Banner

    func testBannerReflectsReconnectingWhenOnlineNoNetworkWhenOfflineAndNothingOtherwise() {
        var sut = policy(autoLogin: false, initial: authenticated())
        XCTAssertNil(sut.bannerState)

        sut.apply(.reconnecting(attempt: 3, isOnline: true, minSupportedSchemaVersion: nil))
        XCTAssertEqual(sut.bannerState, .reconnecting(attempt: 3))

        sut.apply(.reconnecting(attempt: 3, isOnline: false, minSupportedSchemaVersion: nil))
        XCTAssertEqual(sut.bannerState, .noNetwork)

        sut.apply(authenticated())
        XCTAssertNil(sut.bannerState)
    }

    // MARK: - Schema floor

    func testSchemaWarningOnlyWhenTheServerFloorRisesAboveTheClient() {
        func connected(floor: Int?) -> RootSession {
            .connected(.init(
                dataConnection: .awaitingAuth,
                authProcess: .notStarted,
                wasAutoLogin: false,
                hasSavedToken: true,
                minSupportedSchemaVersion: floor
            ))
        }
        XCTAssertNil(AppRootPolicy.schemaWarning(for: connected(floor: nil), localSchemaVersion: 59))
        XCTAssertNil(AppRootPolicy.schemaWarning(for: connected(floor: 59), localSchemaVersion: 59))
        XCTAssertNil(AppRootPolicy.schemaWarning(for: connected(floor: 30), localSchemaVersion: 59),
                     "Trailing the server's current schema is not a fault")
        XCTAssertEqual(AppRootPolicy.schemaWarning(for: connected(floor: 60), localSchemaVersion: 59), .clientIncompatible)
    }

    func testSchemaWarningAlsoReadsTheFloorWhileReconnecting() {
        let session = RootSession.reconnecting(attempt: 1, isOnline: true, minSupportedSchemaVersion: 70)
        XCTAssertEqual(AppRootPolicy.schemaWarning(for: session, localSchemaVersion: 59), .clientIncompatible)
        XCTAssertNil(AppRootPolicy.schemaWarning(for: .connecting, localSchemaVersion: 59))
    }
}
