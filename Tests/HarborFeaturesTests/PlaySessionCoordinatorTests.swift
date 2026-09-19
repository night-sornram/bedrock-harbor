import Foundation
import Testing
@testable import HarborFeatures

@MainActor
private final class FakePlaySessionBackend: PlaySessionBackend {
    var hasCredentials = false
    var validation: PlayValidationResult = .verified(email: "verified@example.com")
    var browserResult: GoogleSignInResult = .cancelled
    var validationCount = 0
    var acceptedCount = 0
    var clearCount = 0
    var clearFails = false
    var holdValidation = false
    var holdBrowser = false
    var ignoreBrowserCancellation = false
    var validationContinuation: CheckedContinuation<PlayValidationResult, Never>?
    var browserContinuation: CheckedContinuation<GoogleSignInResult, Never>?

    func hasSavedCredentials() -> Bool { hasCredentials }
    func validate() async -> PlayValidationResult {
        validationCount += 1
        if holdValidation {
            return await withCheckedContinuation { validationContinuation = $0 }
        }
        return validation
    }
    func signIn(fresh: Bool) async -> GoogleSignInResult {
        if holdBrowser { return await withCheckedContinuation { browserContinuation = $0 } }
        return browserResult
    }
    func cancelSignIn() {
        guard !ignoreBrowserCancellation else { return }
        browserContinuation?.resume(returning: .cancelled)
        browserContinuation = nil
    }
    func accept(_ credentials: GoogleSignInCredentials) throws {
        acceptedCount += 1
        hasCredentials = true
    }
    func clear() async throws {
        clearCount += 1
        if clearFails { throw CocoaError(.fileWriteNoPermission) }
        hasCredentials = false
    }
}

@MainActor
@Suite("Google Play session truth")
struct PlaySessionCoordinatorTests {
    @Test func noCredentialsStaysSignedOutWithoutNetwork() async {
        let backend = FakePlaySessionBackend()
        let session = PlaySessionCoordinator(backend: backend)
        session.restoreIfNeeded()
        await session.waitForValidation()
        #expect(session.status == .signedOut)
        #expect(backend.validationCount == 0)
    }

    @Test func storedCredentialsCheckOnceAndDoNotBlockCaller() async throws {
        let backend = FakePlaySessionBackend()
        backend.hasCredentials = true
        backend.holdValidation = true
        let session = PlaySessionCoordinator(backend: backend)
        session.restoreIfNeeded()
        session.restoreIfNeeded()
        #expect(session.status == .checking)
        #expect(!session.status.isSignedIn)
        for _ in 0..<100 where backend.validationContinuation == nil { await Task.yield() }
        let continuation = try #require(backend.validationContinuation)
        continuation.resume(returning: .verified(email: "verified@example.com"))
        await session.waitForValidation()
        #expect(session.status == .signedIn(email: "verified@example.com", restored: true))
        session.restoreIfNeeded()
        #expect(backend.validationCount == 1)
    }

    @Test func rejectedAndOfflineSessionsAreDifferent() async {
        let backend = FakePlaySessionBackend()
        backend.hasCredentials = true
        backend.validation = .unavailable("Offline")
        let session = PlaySessionCoordinator(backend: backend)
        session.restoreIfNeeded()
        await session.waitForValidation()
        #expect(session.status == .unavailable("Offline"))
        #expect(backend.hasCredentials)
        #expect(backend.clearCount == 0)
        backend.validation = .rejected
        await session.retry()
        #expect(session.status == .expired)
        #expect(!session.status.isSignedIn)
        backend.validation = .verified(email: nil)
        await session.retry()
        #expect(session.status == .signedIn(email: nil, restored: true))
    }

    @Test func cancellationTimeoutAndEmailOnlyCannotSignIn() async {
        for result: GoogleSignInResult in [.cancelled, .timedOut, .failed("Offline"),
                                          .completed(.init(cookies: ["SID": "website-cookie"], email: "cached@example.com"))] {
            let backend = FakePlaySessionBackend()
            backend.browserResult = result
            let session = PlaySessionCoordinator(backend: backend)
            await session.signIn(fresh: true)
            #expect(session.status == .signedOut)
            #expect(backend.acceptedCount == 0)
            #expect(backend.validationCount == 0)
        }
    }

    @Test func completedBrowserAttemptStillRequiresValidation() async {
        let backend = FakePlaySessionBackend()
        backend.browserResult = .completed(.init(cookies: ["oauth_token": "test-candidate"], email: "candidate@example.com"))
        backend.validation = .rejected
        let session = PlaySessionCoordinator(backend: backend)
        await session.signIn(fresh: true)
        #expect(session.status == .expired)
        #expect(backend.acceptedCount == 1)
        #expect(backend.validationCount == 1)
        backend.validation = .verified(email: "verified@example.com")
        await session.signIn(fresh: true)
        #expect(session.status == .signedIn(email: "verified@example.com", restored: false))
    }

    @Test func signOutRejectsLateSuccessfulValidationAndSurvivesRestore() async throws {
        let backend = FakePlaySessionBackend()
        backend.hasCredentials = true
        backend.holdValidation = true
        let session = PlaySessionCoordinator(backend: backend)
        session.restoreIfNeeded()
        for _ in 0..<100 where backend.validationContinuation == nil { await Task.yield() }
        let continuation = try #require(backend.validationContinuation)
        let signOut = Task { await session.signOut() }
        for _ in 0..<100 where session.status != .signingOut { await Task.yield() }
        #expect(session.status == .signingOut)
        // A deliberately cancellation-oblivious backend must not resurrect auth.
        continuation.resume(returning: .verified(email: "late@example.com"))
        await signOut.value
        #expect(session.status == .signedOut)
        #expect(backend.clearCount == 1)
        session.restoreIfNeeded()
        let restarted = PlaySessionCoordinator(backend: backend)
        restarted.restoreIfNeeded()
        #expect(restarted.status == .signedOut)
        #expect(backend.validationCount == 1)
    }

    @Test func signOutCancelsOpenBrowserAndDoesNotAcceptItsResult() async throws {
        let backend = FakePlaySessionBackend()
        backend.holdBrowser = true
        let session = PlaySessionCoordinator(backend: backend)
        let login = Task { await session.signIn(fresh: true) }
        for _ in 0..<100 where backend.browserContinuation == nil { await Task.yield() }
        #expect(backend.browserContinuation != nil)
        await session.signOut()
        await login.value
        #expect(session.status == .signedOut)
        #expect(backend.acceptedCount == 0)
        #expect(backend.clearCount == 1)
    }

    @Test func signOutFailureIsVisibleAndRetryable() async {
        let backend = FakePlaySessionBackend()
        backend.hasCredentials = true
        backend.clearFails = true
        let session = PlaySessionCoordinator(backend: backend)
        await session.signOut()
        #expect(!session.status.isSignedIn)
        #expect(session.status.label == "Unable to verify")
        backend.clearFails = false
        await session.signOut()
        #expect(session.status == .signedOut)
    }

    @Test func staleCompletedBrowserResultCannotUndoSignOut() async throws {
        let backend = FakePlaySessionBackend()
        backend.holdBrowser = true
        backend.ignoreBrowserCancellation = true
        let session = PlaySessionCoordinator(backend: backend)
        let login = Task { await session.signIn(fresh: true) }
        for _ in 0..<100 where backend.browserContinuation == nil { await Task.yield() }
        let callback = try #require(backend.browserContinuation)
        await session.signOut()
        callback.resume(returning: .completed(.init(cookies: ["oauth_token": "late-token"], email: "late@example.com")))
        await login.value
        #expect(session.status == .signedOut)
        #expect(backend.acceptedCount == 0)
        #expect(backend.validationCount == 0)
    }

    @Test func cookieHostMatchingDoesNotIncludeUnrelatedDomains() {
        #expect(GoogleSignInController.isGoogleHost(".accounts.google.com"))
        #expect(GoogleSignInController.isGoogleHost("google.com"))
        #expect(!GoogleSignInController.isGoogleHost("notgoogle.com"))
        #expect(!GoogleSignInController.isGoogleHost("google.com.example.net"))
    }
}
