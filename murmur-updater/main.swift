import Foundation

guard CommandLine.arguments.count == 2 else { exit(64) }
do {
    let result = try UpdateRunner.run(planURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("update_result=\(result.rawValue)")
    exit(result == .installed ? 0 : 2)
} catch {
    // No arbitrary package paths or downloaded text in diagnostics.
    fputs("Update could not complete. The original app or its staged backup is preserved.\n", stderr)
    exit(1)
}
