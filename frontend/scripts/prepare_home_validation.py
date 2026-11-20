"""Run the real Home attention source and shared checks with portable Foundation.

Only the numeric presentation interface and error enum are substituted; wire
decoding, domain records, attention code and assertions come from shipped files.
This never claims SwiftUI, Apple SDK, RealityKit or native build coverage.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".validation-tools/home"
OUT.mkdir(parents=True, exist_ok=True)
collection = (ROOT / "MovementForest/Models/CollectionModels.swift").read_text(encoding="utf-8")
records = collection[collection.index("struct APIIntroMilestone:"):collection.index("struct APIPackPage:")]
expedition = (ROOT / "MovementForest/Models/ExpeditionModels.swift").read_text(encoding="utf-8")
records += expedition[expedition.index("struct ExpeditionReward:"):expedition.index("struct ExpeditionStatus:")]
wire = (ROOT / "MovementForest/Models/ActivityAPIModels.swift").read_text(encoding="utf-8")
wire = wire[wire.index("enum ActivityWire"):wire.index("    static func gameDate")] + "}\n"
interfaces = '''import Foundation
enum ForestError: Error { case invalidData(String) }
enum ActivityDisplayAmount {
    static func decimal(_ value: String) -> Decimal? { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
}
'''
source = (ROOT / "MovementForest/Models/HomeAttention.swift").read_text(encoding="utf-8")
checks = (ROOT / "MovementForestTests/HomeAttentionChecks.swift").read_text(encoding="utf-8")
main = '''
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let count = try HomeAttentionChecks.run(fixtures: fixtures)
precondition(count == 20)
print("PASS: \\(count) shared Home attention/recovery/contract assertions using real Swift source.")
'''
(OUT / "main.swift").write_text(interfaces + records + wire + source + checks + main, encoding="utf-8")
print(OUT / "main.swift")
