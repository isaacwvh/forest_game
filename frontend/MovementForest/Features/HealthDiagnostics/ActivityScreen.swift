import SwiftUI

struct ActivityScreen: View {
    @ObservedObject var store: ActivityStore
    var body: some View {
        List {
            Section {
                Text("Everyday movement, a growing forest.").font(.title2).fontWeight(.semibold)
                Text("Read steps, walking/running distance, active energy, flights climbed and recorded workouts from Apple Health. Enable activity uploads separately to grow your planted plants.")
                    .foregroundStyle(.secondary)
            }
            if store.provider.isFixture {
                Section { Label("Sample activity · not your Health data", systemImage: "testtube.2") }
            }
            if !store.provider.isAvailable {
                Section {
                    Text("Health data is unavailable on this device.")
                    Text("You can still explore the garden.").foregroundStyle(.secondary)
                }
            } else {
                if !store.hasRequestedAccess || store.requestIssue != nil {
                    Section {
                        Text("Choose which activity quantities and recorded workouts to share. Missing optional data does not prevent steps from growing your garden.")
                        Button(store.provider.isFixture ? "Load sample activity" : "Connect Apple Health") { Task { await store.connect() } }
                            .disabled(store.isLoading).accessibilityIdentifier("activity.connect")
                    }
                }
                if let issue = store.requestIssue { Section { Text(issue) } }
                if store.isLoading { Section { ProgressView("Reading activity…") } }
                if let report = store.report {
                    Section("Today") {
                        if let steps = report.todaySteps {
                            DetailRow(title: "Steps read from Health", value: steps.formatted(.number.precision(.fractionLength(0))))
                        } else {
                            Text("No readable step data for today.")
                        }
                        if let issue = report.stepsIssue { Text(issue).foregroundStyle(.secondary) }
                        if let today = report.days.last {
                            DetailRow(title: "Walking + running distance", value: today.walkingRunningDistanceMetres.map { "\(($0 / 1000).formatted(.number.precision(.fractionLength(2)))) km" } ?? "Unavailable")
                            DetailRow(title: "Active energy", value: today.activeEnergyKcal.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kcal" } ?? "Unavailable")
                            DetailRow(title: "Flights climbed", value: today.flightsClimbed.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "Unavailable")
                        }
                        ForEach(report.metricIssues.keys.sorted(), id: \.self) { key in
                            Text("\(metricTitle(key)): \(report.metricIssues[key] ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Last checked \(report.observedAt.formatted(date: .omitted, time: .shortened)) · \(report.timeZoneIdentifier)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Recent days") {
                        ForEach(report.days.reversed()) { day in
                            HStack {
                                Text(ActivityCalendar.dayLabel(day.start, timeZoneIdentifier: report.timeZoneIdentifier))
                                Spacer()
                                Text(day.steps.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "No readable data")
                                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Section("Recorded workouts · recent 7 days") {
                        if let issue = report.workoutsIssue { Text(issue) }
                        if report.workouts.isEmpty { Text("No readable workouts for this period.").foregroundStyle(.secondary) }
                        ForEach(report.workouts) { workout in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(workout.title, systemImage: workout.isRunning ? "figure.run" : "figure.walk")
                                Text("\(workout.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(workout.durationSeconds / 60)) min")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                        Text("Manually entered workouts are excluded. Supported workout types earn additional water from eligible duration; unsupported types are retained for diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if store.hasRequestedAccess {
                    Section {
                        Button("Refresh activity") { Task { await store.refresh() } }.disabled(store.isLoading)
                        Button("Review Health access") { Task { await store.connect() } }.disabled(store.isLoading)
                        Text("An empty result can mean there is no data or it isn’t shared with this app. To change access, open Health, tap your profile, then Apps and Movement Forest. Recorded workouts may arrive after your tracker syncs.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .refreshable { await store.refresh() }
    }

    private func metricTitle(_ key: String) -> String {
        switch key {
        case "walking_running_distance_km": return "Walking + running distance"
        case "active_energy_kcal": return "Active energy"
        case "flights_climbed": return "Flights climbed"
        default: return "Activity"
        }
    }
}
