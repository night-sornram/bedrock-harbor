import Testing
import Foundation
@testable import HarborDomain

@Suite("Domain model identity")
struct MinecraftModelTests {
    @Test func buildIDDescriptionIncludesPackageCodeABIAndChannel() {
        let id = MinecraftBuildID(
            packageIdentifier: "com.mojang.minecraftpe",
            versionCode: 98_200_123_0,
            abi: .arm64v8a,
            channel: .release
        )
        #expect(id.description == "com.mojang.minecraftpe@982001230/arm64-v8a/release")
    }

    @Test func versionDisplayNameDoesNotReplaceOriginalName() {
        let version = MinecraftVersion(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .arm64v8a
            ),
            originalVersionName: "1.21.2.02",
            displayName: "Friendly Name",
            providerID: .googlePlay,
            availability: .known,
            provenance: .bedrockHarborCatalog
        )
        #expect(version.originalVersionName == "1.21.2.02")
        #expect(version.displayName == "Friendly Name")
        #expect(version.id.contains("arm64-v8a"))
    }

    @Test func packageDeliveryExpiration() {
        let build = MinecraftBuildID(
            packageIdentifier: "com.mojang.minecraftpe",
            versionCode: 2,
            abi: .arm64v8a
        )
        let fresh = PackageDelivery(buildID: build, artifacts: [], expiresAt: Date().addingTimeInterval(60))
        let expired = PackageDelivery(buildID: build, artifacts: [], expiresAt: Date().addingTimeInterval(-1))
        #expect(fresh.isExpired == false)
        #expect(expired.isExpired == true)
    }

    @Test func harborErrorDescriptionsDoNotIncludeSecrets() {
        let error = HarborError.reauthenticationRequired(providerID: .googlePlay)
        #expect(error.localizedDescription.contains("google-play"))
        #expect(!error.localizedDescription.lowercased().contains("token"))
    }
}
