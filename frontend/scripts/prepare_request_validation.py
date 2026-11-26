"""Run existing request/recovery XCTest cases portably with the shipped coordinators.

Generate with Python, then run `swift test` in frontend/.validation-tools/integration
with FOREST_FIXTURES set to the absolute MovementForest/Resources/Fixtures path.
Observation, diagnostics, effects, asset resolution and OS hashing use Linux
interfaces. Wire models, persistence, editor/collection coordinators and the
selected native assertions run unchanged. This is not an Apple SDK/UI build.
"""

import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
front = root / "frontend"
out = front / ".validation-tools/integration"
tests = out / "Tests/IntegrationTests"
tests.mkdir(parents=True, exist_ok=True)
subprocess.run(
    [
        sys.executable,
        str(front / "scripts/prepare_strategy_validation.py"),
        "--typecheck-store",
    ],
    check=True,
)
subprocess.run(
    [sys.executable, str(front / "scripts/prepare_auth_validation.py")], check=True
)


def read(p):
    return (front / p).read_text(encoding="utf-8")


def block(s, marker):
    start = s.index(marker)
    opening = s.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (s[end] == "{") - (s[end] == "}")
        end += 1
    return s[start:end] + "\n"


def fixtures(s):
    return re.sub(
        r'try XCTUnwrap\(Bundle.main.url\(forResource: ("[^"]+"|name), withExtension: "json", subdirectory: "Fixtures"\)\)',
        r'URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOREST_FIXTURES"]!).appendingPathComponent(\1 + ".json")',
        s,
    )


source_path = (
    root
    / "backend/.local-strategy-validation/portable"
    / (root / "backend/.local-strategy-validation/portable/source.txt")
    .read_text()
    .strip()
)
source = source_path.read_text().split("// Console validation")[0]
source = source.replace(block(source, "struct APIInventoryCapacity:"), "")
api = read("MovementForest/Services/APIClient.swift")
source = source.replace(
    block(source, "struct RequestRecovery:"), block(api, "struct RequestRecovery:")
)
# Persistence runs the shipped implementation; only its OS hashing interface is substituted.
disk = read("MovementForest/Services/AccountDiskStore.swift")
source = source.replace(
    block(source, "struct AccountDiskStore"),
    disk[
        disk.index("private struct AccountDiskRecord") : disk.index(
            "struct ConfirmedGardenCache"
        )
    ],
)
auth = read(".validation-tools/auth/AuthChecks.swift")
source += block(auth, "enum SHA256")
source = source.replace(
    "requestID: String?, scope: String)", "requestID: String? = nil, scope: String)"
)
source += "\nimport XCTest\nstruct BundleAssetCatalog: AssetCatalogProviding { let species: [SpeciesManifest] = []; init() throws {} }\n"
editor = read("MovementForestTests/GardenEditorTests.swift")
for marker in [
    "private struct EditorContract:",
    "private final class MemoryEditJournal:",
    "private final class EditorTestService:",
]:
    item = fixtures(block(editor, marker))
    if "EditorTestService" in marker:
        item = "@MainActor\n" + item
    source += item
source += fixtures(
    block(
        read("MovementForestTests/GardenStrategyTests.swift"),
        "struct GardenStrategyContract:",
    )
)
selected = [
    "testEditorRenderingCacheInvalidatesOnDraftAndRefreshButNotSelection",
    "testAtomicSnapshotLoadsOnceAndFreshSaveDoesNotReload",
    "testLostFreshResponseReplaysThenReadsCurrentSnapshot",
    "testModernSaveChecksStrategyInTheEditWithoutAPreviewRequest",
    "testInitialVerifiedSnapshotAvoidsAnotherNetworkRead",
    "testUnsentJournalAtRelaunchLoadsCatalogueAfterFreshCommit",
    "testConfirmedLevelCapacitySurvivesLaterStaleInventory",
    "testFailedActivityPreflightPreventsMembershipMutation",
    "testSuccessfulActivityPreflightUsesLatestConfirmedState",
]
source += "@MainActor\nfinal class MergedEditorTests: XCTestCase {\n" + block(
    editor, "    private func makeStore"
)
for name in selected:
    source += block(editor, "    func " + name + "(")
source += "}\n"
collection = read("MovementForest/Models/CollectionModels.swift")
source += collection[: collection.index("struct APICollectionRepository:")]
discovery = read("MovementForest/Models/CatalogDiscoveryModels.swift")
source += discovery.replace(
    block(discovery, "struct APICatalogDiscoveryRepository:"), ""
)
source += '\nenum ActivityDisplayAmount { static func decimal(_ value: String) -> Decimal? { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) } }\n'
for p in [
    "MovementForest/Services/CatalogDiscoveryStore.swift",
    "MovementForest/Services/CollectionCoordinator.swift",
]:
    source += read(p).replace("import Combine", "")
native = read("MovementForestTests/CollectionTests.swift")
header = native[: native.index("@MainActor\nfinal class CollectionTests")]
header = re.sub(r"^(?:import|@testable import) .+\n", "", header, flags=re.MULTILINE)
source += fixtures(header)
selected_collection = [
    "testVerifiedCatalogueVersionReusesGardenCatalogueAndReloadsOnChange",
    "testLostExchangeResponseRelaunchReplaysExactBytesAndUUID",
    "testCannotSendIfDurableSaveFails",
    "testCompletionDiskFailureRetainsRequestAndOpeningResultSurvivesRelaunch",
    "testDefinitiveRejectionClearsOperationAndAuthFailureKeepsIt",
    "testLateDetachedResponseCannotGrantToAnotherAccount",
    "testCachedCatalogMetadataSurvivesCollectionRefreshFailure",
    "testJournalRejectsTamperingAndSeparatesAccountScopes",
]
source += "@MainActor\nfinal class MergedCollectionTests: XCTestCase {\n"
for name in selected_collection:
    item = block(native, "    func " + name + "(")
    signature, body = item.split("{", 1)
    if "async" not in signature:
        signature = signature.replace(" throws ", " ").rstrip() + " async throws "
    source += signature + "{" + body
source += "}\n"
strategy_tests = read("MovementForestTests/GardenStrategyTests.swift")
source += block(strategy_tests, "final class GardenStrategyTests:")
wire = read("MovementForest/Models/ActivityAPIModels.swift")
source += (
    wire[wire.index("enum ActivityWire") : wire.index("    static func gameDate")]
    + "}\n"
)
source += block(
    read("MovementForest/Services/AppResumeCoordinator.swift"), "enum LifecycleClock"
)
(tests / "IntegrationTests.swift").write_text(source, encoding="utf-8")
(out / "Package.swift").write_text(
    '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "MergedForestChecks", targets: [.testTarget(name: "IntegrationTests", path: "Tests/IntegrationTests")])\n'
)
print(
    "Prepared",
    len(selected) + len(selected_collection) + 5,
    "actual native editor/collection/strategy regressions with platform interfaces.",
)
