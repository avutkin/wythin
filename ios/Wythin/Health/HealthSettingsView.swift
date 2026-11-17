import SwiftUI

struct HealthSettingsSection: View {
    @State private var health = HealthSyncCoordinator.shared
    @State private var confirmCloud = false
    @State private var confirmDelete = false

    var body: some View {
        Section("APPLE HEALTH") {
            Label("Workouts from Apple Watch and Health", systemImage: "heart.text.clipboard")
            Text("Import saved workouts and available heart rate, HRV SDNN, energy, distance and steps. Compare measurements before, during and after each activity.")
                .font(.footnote).foregroundStyle(Theme.dim)
            if health.available {
                if health.enabled {
                    Button(health.isWorking ? "Syncing…" : "Sync now") { Task { await health.synchronize() } }
                        .disabled(health.isWorking)
                    Button("Disconnect Apple Health") { Task { await health.disconnect() } }
                } else {
                    if health.pendingDeletion {
                        Button("Retry cloud deletion") { Task { await health.synchronize() } }.disabled(health.isWorking)
                    } else {
                        Button("Connect Apple Health") { Task { await health.connect() } }.disabled(health.isWorking)
                    }
                }
                Text(health.status).font(.footnote).foregroundStyle(Theme.dim)
                if let date = health.lastSync { Text("Last checked: \(date.formatted())").font(.caption).foregroundStyle(Theme.dim) }
                Toggle("Save Health data to Wythin cloud", isOn: Binding(get: { health.cloudEnabled }, set: { on in
                    if on { confirmCloud = true } else { Task { await health.setCloudEnabled(false) } }
                })).disabled(!health.enabled)
                if health.cloudEnabled && health.pendingCount > 0 {
                    Text("\(health.pendingCount) changes waiting to upload").font(.caption).foregroundStyle(Theme.dim)
                }
                Text("Read access is managed in Health → your profile → Apps → Wythin. Disconnecting here keeps your saved history. Background updates depend on iOS and may arrive later.")
                    .font(.caption).foregroundStyle(Theme.dim)
                Button("Delete imported Health data", role: .destructive) { confirmDelete = true }
            } else {
                Text("HealthKit is unavailable on this device.").foregroundStyle(Theme.dim)
            }
            if let error = health.lastError { Text(error).font(.footnote).foregroundStyle(Theme.warn) }
        }
        .listRowBackground(Theme.card)
        .alert("Save Health data to Wythin cloud?", isPresented: $confirmCloud) {
            Button("Keep on this iPhone", role: .cancel) {}
            Button("Allow cloud sync") { Task { await health.setCloudEnabled(true) } }
        } message: {
            Text("Wythin will send imported workouts, measurements, source information and their analysis to \(health.serverURL.host ?? "your Wythin server") for storage. Your Apple Health permission alone does not enable this. This archive belongs to this iPhone installation. You can disable syncing or delete it here.")
        }
        .alert("Delete imported Health data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await health.deleteImportedData() } }
        } message: {
            Text("Remove imported workouts and measurements from Wythin on this iPhone and its Health cloud archive, and stop syncing. Your records in Apple Health and manually logged Wythin activities remain. If offline, cloud deletion finishes when the connection returns.")
        }
    }
}

struct HealthActivityRow: View {
    let entry: ActivityLog
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(entry.displayName, systemImage: "figure.run").font(Theme.monoBody)
                Spacer()
                Text(entry.durationString).font(Theme.monoLabel).foregroundStyle(Theme.dim)
            }
            Label("Apple Health", systemImage: "heart.fill").font(.caption).foregroundStyle(Theme.breathe)
            Text(entry.startedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.dim)
        }.padding(.vertical, 8).foregroundStyle(Theme.text)
    }
}
