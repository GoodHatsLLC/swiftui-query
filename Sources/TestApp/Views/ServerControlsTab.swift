import SwiftUI
import SwiftUIQuery

struct ServerControlsTab: View {
    @Environment(\.mockServer) private var server

    @State private var isServerDown = false
    @State private var failureRate: Double = 0.0
    @State private var minLatency: Double = 200
    @State private var maxLatency: Double = 800
    @State private var requestCount: Int = 0

    @Environment(\.queryClient) private var client

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Status") {
                    Toggle("Server Down", isOn: $isServerDown)
                        .onChange(of: isServerDown) { _, newValue in
                            Task {
                                await server.setServerDown(newValue)
                            }
                        }

                    HStack {
                        Text("Requests Made")
                        Spacer()
                        Text("\(requestCount)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Reset Request Counter") {
                        Task {
                            await server.resetRequestCount()
                            requestCount = 0
                        }
                    }
                }

                Section("Latency Simulation") {
                    VStack(alignment: .leading) {
                        Text("Min Latency: \(Int(minLatency))ms")
                        Slider(value: $minLatency, in: 0...3000, step: 50)
                            .onChange(of: minLatency) { _, _ in
                                updateLatency()
                            }
                    }

                    VStack(alignment: .leading) {
                        Text("Max Latency: \(Int(maxLatency))ms")
                        Slider(value: $maxLatency, in: 0...5000, step: 50)
                            .onChange(of: maxLatency) { _, _ in
                                updateLatency()
                            }
                    }
                }

                Section("Error Simulation") {
                    VStack(alignment: .leading) {
                        Text("Failure Rate: \(Int(failureRate * 100))%")
                        Slider(value: $failureRate, in: 0...1, step: 0.05)
                            .onChange(of: failureRate) { _, newValue in
                                Task {
                                    await server.setFailureRate(newValue)
                                }
                            }
                    }
                }

                Section("Presets") {
                    Button("Fast & Reliable") {
                        applyPreset(.fast)
                    }

                    Button("Slow Network") {
                        applyPreset(.slow)
                    }

                    Button("Flaky Connection") {
                        applyPreset(.flaky)
                    }

                    Button("Unreliable") {
                        applyPreset(.unreliable)
                    }
                }

                Section("Cache Controls") {
                    Button("Clear All Cache") {
                        Task {
                            await client.clear()
                        }
                    }
                    .foregroundStyle(.red)

                    Button("Invalidate Users") {
                        Task {
                            await client.invalidate(tag: .users)
                        }
                    }

                    Button("Invalidate Posts") {
                        Task {
                            await client.invalidate(tag: .posts)
                        }
                    }

                    Button("Invalidate Comments") {
                        Task {
                            await client.invalidate(tag: .comments)
                        }
                    }

                    Button("Run Garbage Collection") {
                        Task {
                            await client.collectGarbage()
                        }
                    }
                }

                Section("Cache Stats") {
                    CacheStatsView()
                }
            }
            .navigationTitle("Server Controls")
            .task {
                await refreshStats()
            }
            .refreshable {
                await refreshStats()
            }
        }
    }

    private func updateLatency() {
        let min = UInt64(max(minLatency, 0))
        let max = UInt64(max(maxLatency, minLatency))
        Task {
            await server.setLatency(min...max)
        }
    }

    private func applyPreset(_ config: MockServer.Configuration) {
        minLatency = Double(config.latencyRange.lowerBound)
        maxLatency = Double(config.latencyRange.upperBound)
        failureRate = config.failureRate
        isServerDown = config.isDown

        Task {
            await server.updateConfiguration(config)
        }
    }

    private func refreshStats() async {
        requestCount = await server.getRequestCount()
    }
}

struct CacheStatsView: View {
    @Environment(\.queryClient) private var client

    @State private var stats: CacheStats?

    var body: some View {
        Group {
            if let stats = stats {
                statsContent(stats)
            } else {
                Text("Loading stats...")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await refreshStats()
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: CacheStats) -> some View {
        HStack {
            Text("Total Entries")
            Spacer()
            Text("\(stats.totalEntries)")
                .foregroundStyle(.secondary)
        }

        HStack {
            Text("Stale Entries")
            Spacer()
            Text("\(stats.staleEntries)")
                .foregroundStyle(.orange)
        }

        HStack {
            Text("Expired Entries")
            Spacer()
            Text("\(stats.expiredEntries)")
                .foregroundStyle(.red)
        }

        HStack {
            Text("Memory Entries")
            Spacer()
            Text("\(stats.memoryEntries)")
                .foregroundStyle(.blue)
        }
    }

    private func refreshStats() async {
        stats = await client.stats()
    }
}
