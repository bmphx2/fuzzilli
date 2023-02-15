// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Fuzzilli

let Seconds = 1.0
let Minutes = 60.0 * Seconds
let Hours   = 60.0 * Minutes
let Days    = 24.0 * Hours

// A very basic terminal UI.
class TerminalUI {
    // If true, the next program generated by the fuzzer will be printed to the screen.
    var printNextGeneratedProgram = false
    // If true, the next interesting program found by this fuzzer will be printed to the screen.
    var printNextInterestingProgram = false

    // Timestamp when the last interesting program was found
    var lastInterestingProgramFound = Date()

    init(for fuzzer: Fuzzer) {
        // Event listeners etc. have to be registered on the fuzzer's queue
        fuzzer.sync {
            self.initOnFuzzerQueue(fuzzer)

        }
    }

    func initOnFuzzerQueue(_ fuzzer: Fuzzer) {
        // Register log event listener now to be able to print log messages
        // generated during fuzzer initialization
        fuzzer.registerEventListener(for: fuzzer.events.Log) { ev in
            let color = self.colorForLevel[ev.level]!
            if ev.origin == fuzzer.id {
                print("\u{001B}[0;\(color.rawValue)m[\(ev.label)] \(ev.message)\u{001B}[0;\(Color.reset.rawValue)m")
            } else {
                // Mark message as coming from a worker by including its id
                let shortId = ev.origin.uuidString.split(separator: "-")[0]
                print("\u{001B}[0;\(color.rawValue)m[\(shortId):\(ev.label)] \(ev.message)\u{001B}[0;\(Color.reset.rawValue)m")
            }
        }

        fuzzer.registerEventListener(for: fuzzer.events.CrashFound) { crash in
            if crash.isUnique {
                print("########## Unique Crash Found ##########")
                print(fuzzer.lifter.lift(crash.program, withOptions: .includeComments))
            }
        }

        fuzzer.registerEventListener(for: fuzzer.events.ProgramGenerated) { program in
            if self.printNextGeneratedProgram {
                print("--------- Randomly Sampled Generated Program -----------")
                print(fuzzer.lifter.lift(program, withOptions: .includeComments))
                self.printNextGeneratedProgram = false
            }
        }

        fuzzer.registerEventListener(for: fuzzer.events.InterestingProgramFound) { program, origin in
            self.lastInterestingProgramFound = Date()
            if self.printNextInterestingProgram {
                print("--------- Randomly Sampled Interesting Program -----------")
                print(fuzzer.lifter.lift(program, withOptions: .includeComments))
                self.printNextInterestingProgram = false
            }
        }

        // Do everything else after fuzzer initialization finished
        fuzzer.registerEventListener(for: fuzzer.events.Initialized) {
            if let stats = Statistics.instance(for: fuzzer) {
                fuzzer.registerEventListener(for: fuzzer.events.Shutdown) { _ in
                    print("\n++++++++++ Fuzzer Finished ++++++++++\n")
                    self.printStats(stats.compute(), of: fuzzer)
                }

                // We could also run our own timer on the main queue instead if we want to
                fuzzer.timers.scheduleTask(every: 60 * Seconds) {
                    self.printStats(stats.compute(), of: fuzzer)
                    print()
                }

                // Randomly sample generated and interesting programs and print them.
                // The goal of this is to give users a better "feeling" for what the fuzzer is currently doing.
                fuzzer.timers.scheduleTask(every: 5 * Minutes) {
                    self.printNextInterestingProgram = true
                    self.printNextGeneratedProgram = true
                }
            }
        }
    }

    func printStats(_ stats: Fuzzilli_Protobuf_Statistics, of fuzzer: Fuzzer) {
        let state: String
        switch fuzzer.state {
        case .uninitialized:
            fatalError("This state should never be observed here")
        case .waiting:
            state = "Waiting for corpus from manager"
        case .corpusImport:
            let progress = String(format: "%.2f%", fuzzer.corpusImportProgress() * 100)
            state = "Corpus import (\(progress)% completed)"
        case .corpusGeneration:
            state = "Initial corpus generation (with \(fuzzer.corpusGenerationEngine.name))"
        case .fuzzing:
            state = "Fuzzing (with \(fuzzer.engine.name))"
        }

        let timeSinceLastInterestingProgram = -lastInterestingProgramFound.timeIntervalSinceNow

        let maybeAvgCorpusSize = stats.numChildNodes > 0 ? " (global average: \(Int(stats.avgCorpusSize)))" : ""

        print("""
        Fuzzer Statistics
        -----------------
        Fuzzer state:                 \(state)
        Uptime:                       \(formatTimeInterval(fuzzer.uptime()))
        Total Samples:                \(stats.totalSamples)
        Interesting Samples Found:    \(stats.interestingSamples)
        Last Interesting Sample:      \(formatTimeInterval(timeSinceLastInterestingProgram))
        Valid Samples Found:          \(stats.validSamples)
        Corpus Size:                  \(fuzzer.corpus.size)\(maybeAvgCorpusSize)
        Correctness Rate:             \(String(format: "%.2f%%", stats.correctnessRate * 100)) (\(String(format: "%.2f%%", stats.globalCorrectnessRate * 100)))
        Timeout Rate:                 \(String(format: "%.2f%%", stats.timeoutRate * 100)) (\(String(format: "%.2f%%", stats.globalTimeoutRate * 100)))
        Crashes Found:                \(stats.crashingSamples)
        Timeouts Hit:                 \(stats.timedOutSamples)
        Coverage:                     \(String(format: "%.2f%%", stats.coverage * 100))
        Avg. program size:            \(String(format: "%.2f", stats.avgProgramSize))
        Avg. corpus program size:     \(String(format: "%.2f", stats.avgCorpusProgramSize))
        Connected nodes:              \(stats.numChildNodes)
        Execs / Second:               \(String(format: "%.2f", stats.execsPerSecond))
        Fuzzer Overhead:              \(String(format: "%.2f", stats.fuzzerOverhead * 100))%
        Total Execs:                  \(stats.totalExecs)
        """)
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let days = Int(interval / Days)
        let hours = Int(interval / Hours) % 24
        let minutes = Int(interval / Minutes) % 60
        let seconds = Int(interval / Seconds) % 60
        return String(format: "%id %ih %im %is", days, hours, minutes, seconds)
    }

    private enum Color: Int {
        case reset   = 0
        case black   = 30
        case red     = 31
        case green   = 32
        case yellow  = 33
        case blue    = 34
        case magenta = 35
        case cyan    = 36
        case white   = 37
    }

    // The color with which to print log entries.
    private let colorForLevel: [LogLevel: Color] = [
        .verbose: .cyan,
        .info:    .white,
        .warning: .yellow,
        .error:   .red,
        .fatal:   .magenta
    ]
}
