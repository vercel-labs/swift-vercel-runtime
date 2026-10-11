import Foundation
import PackagePlugin

/// `swift package --disable-sandbox vercel`
///
/// Cross-compiles an executable product with the Swift Static Linux SDK and writes Vercel's
/// Build Output API (v3) to `.vercel/output`, ready for `vercel deploy --prebuilt`.
///
/// The function uses Vercel's `executable` runtime (`provided.al2023` plus Vercel's runtime
/// layer). Its entrypoint is `VercelBootstrap`, which starts the app (any Swift HTTP server that
/// listens on a port), proxies requests to it and speaks the runtime protocol on its behalf.
@main
struct VercelPlugin: CommandPlugin {
    static let usage = """
        OVERVIEW: Build a Swift server for Vercel's native `executable` runtime.

        USAGE: swift package --disable-sandbox vercel [options]

        OPTIONS:
          --product <name>         Executable product to build. Defaults to the package's only
                                   executable product.
          --architecture <arch>    arm64 (default) or x86_64.
          --swift-sdk <id>         Swift SDK to build with. Defaults to the Static Linux SDK
                                   (aarch64-swift-linux-musl or x86_64-swift-linux-musl).
          --swift-sdks-path <path> Directory with installed Swift SDKs. Defaults to
                                   $SWIFT_VERCEL_SDKS_PATH, then SwiftPM's default.
          --configuration <cfg>    release (default) or debug.
          --output <path>          Build Output directory. Defaults to .vercel/output.
          --static-dir <path>      Directory to serve from Vercel's CDN (for example Public).
          --memory <mb>            Function memory in MB.
          --max-duration <s>       Function maximum duration in seconds.
          --region <id>            Function region. Repeat for several regions.
          --no-strip               Keep debug symbols.
          --help                   Show this help.

        Use `--disable-sandbox`: the plugin runs a nested `swift build` with the Static Linux SDK,
        which needs the SwiftPM caches and network access that the plugin sandbox blocks.

        The app is a normal Swift server: it should listen on 127.0.0.1 (or 0.0.0.0), ideally on
        the PORT environment variable. Cron jobs are read from `crons` in vercel.json next to
        Package.swift.

        Deploy the result with `vercel deploy --prebuilt`, or let Vercel build it from Git with
        scripts/vercel-install-swift.sh (see the README).
        """

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var extractor = ArgumentExtractor(arguments)
        if extractor.extractFlag(named: "help") > 0 {
            print(Self.usage)
            return
        }

        let productName = extractor.extractOption(named: "product").last
        let architecture = try Architecture(extractor.extractOption(named: "architecture").last ?? "arm64")
        let requestedSDK = extractor.extractOption(named: "swift-sdk").last
        let swiftSDK = requestedSDK ?? architecture.staticLinuxSDK
        // The environment fallback is set by the .vercel/bin/swift wrapper that
        // scripts/vercel-install-swift.sh writes for Git deployments.
        let environment = ProcessInfo.processInfo.environment
        let swiftSDKsPath = extractor.extractOption(named: "swift-sdks-path").last ?? environment["SWIFT_VERCEL_SDKS_PATH"]
        let configuration = extractor.extractOption(named: "configuration").last ?? "release"
        let outputPath = extractor.extractOption(named: "output").last ?? ".vercel/output"
        let staticDirectory = extractor.extractOption(named: "static-dir").last
        let memory = try extractor.extractOption(named: "memory").last.map { try positiveInteger($0, option: "memory") }
        let maxDuration = try extractor.extractOption(named: "max-duration").last.map {
            try positiveInteger($0, option: "max-duration")
        }
        let regions = extractor.extractOption(named: "region")
        let strip = extractor.extractFlag(named: "no-strip") == 0

        guard ["release", "debug"].contains(configuration) else {
            throw PluginError.invalidArgument("--configuration must be release or debug, got '\(configuration)'")
        }
        if !extractor.remainingArguments.isEmpty {
            throw PluginError.invalidArgument(
                "unknown arguments: \(extractor.remainingArguments.joined(separator: " "))\n\n\(Self.usage)"
            )
        }

        let packageDirectory = context.package.directoryURL
        let product = try executableProduct(named: productName, in: context.package)
        // Read before building so a broken vercel.json fails fast.
        let crons = try readCrons(in: packageDirectory)
        let swift = try context.tool(named: "swift").url
        let scratchPath = packageDirectory.appending(path: ".build/vercel")
        // SwiftPM reads SDKs from ~/.swiftpm/swift-sdks by default, and finds the home directory from
        // the user database rather than $HOME, so a cached SDK has to be passed explicitly.
        let sdksArguments = swiftSDKsPath.map {
            ["--swift-sdks-path", URL(fileURLWithPath: $0, relativeTo: packageDirectory).standardizedFileURL.path()]
        } ?? []

        // 0. Catch toolchain/SDK mismatches up front instead of after a minute of compiler errors.
        if swiftSDK.hasSuffix("-swift-linux-musl") {
            let versionOutput = try run(swift, ["--version"], in: packageDirectory, captureOutput: true)
            // An explicitly chosen SDK may be a custom one, so only the default is checked by name.
            let sdkList = requestedSDK == nil
                ? try run(swift, ["sdk", "list"] + sdksArguments, in: packageDirectory, captureOutput: true)
                : nil
            if let problem = ToolchainCheck.problem(swiftVersionOutput: versionOutput, sdkListOutput: sdkList) {
                throw PluginError.toolchain(problem)
            }
        }

        // 1. Cross-compile the app and the bootstrap that runs it.
        guard ![Self.bootstrapName, "bootstrap", "vercel-bootstrap.json"].contains(product.name) else {
            throw PluginError.invalidArgument("the executable product cannot be named '\(product.name)'; rename it")
        }
        print("Building '\(product.name)' for Vercel (\(architecture.rawValue), \(swiftSDK), \(configuration))")
        var buildArguments = [
            "build",
            "--configuration", configuration,
            "--swift-sdk", swiftSDK,
            "--scratch-path", scratchPath.path(),
        ] + sdksArguments
        let binPath: URL
        do {
            for name in [product.name, Self.bootstrapProduct] {
                var productArguments = buildArguments + ["--product", name]
                if strip {
                    productArguments += ["-Xlinker", "--strip-all"]
                }
                try run(swift, productArguments, in: packageDirectory)
            }
            buildArguments.append("--show-bin-path")
            binPath = URL(fileURLWithPath: try run(swift, buildArguments, in: packageDirectory, captureOutput: true))
        } catch let error as PluginError {
            throw PluginError.buildFailed(
                """
                \(error)

                Make sure `swift` is the swift.org toolchain, the Swift SDK '\(swiftSDK)' for the same
                Swift version is installed (`swift sdk list`), and the plugin runs with
                `swift package --disable-sandbox vercel`.
                Static Linux SDK: https://www.swift.org/documentation/articles/static-linux-getting-started.html
                """
            )
        }

        let binary = binPath.appending(path: product.name)
        let bootstrapBinary = binPath.appending(path: Self.bootstrapProduct)
        try checkBinary(binary, architecture: architecture)
        try checkBinary(bootstrapBinary, architecture: architecture)

        // 2. Write the Build Output API directory.
        let output = URL(fileURLWithPath: outputPath, relativeTo: packageDirectory).standardizedFileURL
        try prepareOutputDirectory(output)

        let function = output.appending(path: "functions/index.func")
        try FileManager.default.createDirectory(at: function, withIntermediateDirectories: true)

        let executable = function.appending(path: product.name)
        let bootstrap = function.appending(path: Self.bootstrapName)
        for (source, destination) in [(binary, executable), (bootstrapBinary, bootstrap)] {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path())
        }
        // Tells the bootstrap which executable to run and which paths are cron jobs.
        try writeJSON(
            ["executable": product.name, "crons": crons.compactMap { $0["path"] }] as [String: Any],
            to: function.appending(path: "vercel-bootstrap.json")
        )

        // SwiftPM resource bundles are looked up next to the executable at runtime.
        let resourceBundles = try FileManager.default.contentsOfDirectory(at: binPath, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "resources" }
        for bundle in resourceBundles {
            try FileManager.default.copyItem(at: bundle, to: function.appending(path: bundle.lastPathComponent))
        }

        var functionConfig: [String: Any] = [
            "runtime": "executable",
            "handler": Self.bootstrapName,
            "architecture": architecture.rawValue,
            "supportsResponseStreaming": true,
        ]
        if let memory { functionConfig["memory"] = memory }
        if let maxDuration { functionConfig["maxDuration"] = maxDuration }
        if !regions.isEmpty { functionConfig["regions"] = regions }
        try writeJSON(functionConfig, to: function.appending(path: ".vc-config.json"))

        if let staticDirectory {
            let source = URL(fileURLWithPath: staticDirectory, relativeTo: packageDirectory).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path()) else {
                throw PluginError.invalidArgument("--static-dir '\(staticDirectory)' does not exist")
            }
            try FileManager.default.copyItem(at: source, to: output.appending(path: "static"))
        }

        // Static files (if any) first, then every other path goes to the single function.
        var outputConfig: [String: Any] = [
            "version": 3,
            "routes": [
                ["handle": "filesystem"],
                ["src": "/(.*)", "dest": "/index"],
            ],
        ]
        if !crons.isEmpty {
            outputConfig["crons"] = crons
        }
        try writeJSON(outputConfig, to: output.appending(path: "config.json"))

        func megabytes(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path())[.size] as? Int) ?? 0) / 1_000_000
        }
        print(
            "Wrote \(relativePath(output, to: packageDirectory)) (\(product.name): \(megabytes(executable)) MB, bootstrap: \(megabytes(bootstrap)) MB, \(architecture.rawValue))"
        )
        // In a Vercel build (a Git deployment), Vercel deploys the output itself.
        if environment["VERCEL"] != "1" {
            print("Deploy with: vercel deploy --prebuilt")
        }
    }

    /// The bootstrap product in this package, and its file name in the function.
    ///
    /// Vercel's `executable` runtime starts the file named `executable` (the Go builder lays out
    /// standalone servers the same way). Never name a function file `bootstrap`: on
    /// `provided.al2023`, AWS Lambda runs a file with that name as the Lambda runtime itself,
    /// bypassing Vercel's runtime.
    static let bootstrapProduct = "VercelBootstrap"
    static let bootstrapName = "executable"

    private func executableProduct(named name: String?, in package: Package) throws -> ExecutableProduct {
        let executables = package.products.compactMap { $0 as? ExecutableProduct }
        if let name {
            guard let product = executables.first(where: { $0.name == name }) else {
                throw PluginError.invalidArgument(
                    "no executable product named '\(name)'. Available: \(executables.map(\.name).joined(separator: ", "))"
                )
            }
            return product
        }
        switch executables.count {
        case 1: return executables[0]
        case 0: throw PluginError.invalidArgument("the package has no executable products")
        default:
            throw PluginError.invalidArgument(
                "the package has several executable products; pass --product with one of: \(executables.map(\.name).joined(separator: ", "))"
            )
        }
    }

    /// Reads `crons` from `vercel.json`, the same place `vercel build` reads them from.
    private func readCrons(in packageDirectory: URL) throws -> [[String: String]] {
        let file = packageDirectory.appending(path: "vercel.json")
        guard FileManager.default.fileExists(atPath: file.path()) else { return [] }
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw PluginError.invalidArgument("vercel.json must contain a JSON object")
        }

        // Vercel applies its build settings itself before running the build command.
        let buildSettings: Set = ["$schema", "crons", "installCommand", "buildCommand", "framework", "ignoreCommand", "git", "github"]
        let ignored = config.keys.filter { !buildSettings.contains($0) }.sorted()
        if !ignored.isEmpty {
            print("note: swift package vercel only applies `crons` from vercel.json; ignoring \(ignored.joined(separator: ", "))")
        }

        guard let value = config["crons"] else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw PluginError.invalidArgument("vercel.json `crons` must be an array of { \"path\", \"schedule\" } objects")
        }
        return try entries.enumerated().map { index, entry in
            guard let path = entry["path"] as? String, path.hasPrefix("/"),
                let schedule = entry["schedule"] as? String,
                schedule.split(separator: " ", omittingEmptySubsequences: true).count == 5
            else {
                throw PluginError.invalidArgument(
                    "vercel.json crons[\(index)] needs a `path` starting with / and a five-field cron `schedule`"
                )
            }
            return ["path": path, "schedule": schedule]
        }
    }

    /// Refuses to delete a directory that does not look like a Build Output directory.
    private func prepareOutputDirectory(_ output: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: output.path()) else { return }
        let contents = try fileManager.contentsOfDirectory(atPath: output.path())
        guard contents.isEmpty || contents.contains("config.json") else {
            throw PluginError.invalidArgument(
                "refusing to overwrite '\(output.path())': it is not empty and has no config.json"
            )
        }
        try fileManager.removeItem(at: output)
    }

    /// Verifies the binary is a Linux ELF executable for the requested architecture.
    private func checkBinary(_ binary: URL, architecture: Architecture) throws {
        let data = try Data(contentsOf: binary, options: .alwaysMapped)
        guard data.count > 64, data.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]), data[data.startIndex + 4] == 2 else {
            throw PluginError.invalidBinary("\(binary.path()) is not a 64-bit ELF executable")
        }
        func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(data[data.startIndex + offset + index]) << (8 * index)
            }
            return value
        }
        let machine = read(UInt16.self, at: 0x12)
        guard machine == architecture.elfMachine else {
            throw PluginError.invalidBinary(
                "\(binary.lastPathComponent) was built for ELF machine \(machine), expected \(architecture.rawValue). Check --swift-sdk."
            )
        }
        // A PT_INTERP program header means the binary needs a dynamic loader and shared libraries.
        let programHeaderOffset = Int(read(UInt64.self, at: 0x20))
        let programHeaderSize = Int(read(UInt16.self, at: 0x36))
        let programHeaderCount = Int(read(UInt16.self, at: 0x38))
        for index in 0..<programHeaderCount {
            let offset = programHeaderOffset + index * programHeaderSize
            guard offset + 4 <= data.count else { break }
            if read(UInt32.self, at: offset) == 3 {
                Diagnostics.warning(
                    "\(binary.lastPathComponent) is dynamically linked; every shared library it needs must exist in provided.al2023."
                )
                return
            }
        }
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String], in directory: URL, captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
        }
        try process.run()
        let output = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PluginError.processFailed(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " "))",
                process.terminationStatus
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url)
    }

    private func relativePath(_ url: URL, to base: URL) -> String {
        var path = url.path()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let basePath = base.path().hasSuffix("/") ? base.path() : base.path() + "/"
        return path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : path
    }

    private func positiveInteger(_ value: String, option: String) throws -> Int {
        guard let number = Int(value), number > 0 else {
            throw PluginError.invalidArgument("--\(option) must be a positive integer, got '\(value)'")
        }
        return number
    }
}

enum Architecture: String {
    case arm64
    case x86_64

    init(_ value: String) throws {
        switch value {
        case "arm64", "aarch64": self = .arm64
        case "x86_64", "amd64": self = .x86_64
        default: throw PluginError.invalidArgument("--architecture must be arm64 or x86_64, got '\(value)'")
        }
    }

    var staticLinuxSDK: String {
        switch self {
        case .arm64: "aarch64-swift-linux-musl"
        case .x86_64: "x86_64-swift-linux-musl"
        }
    }

    var elfMachine: UInt16 {
        switch self {
        case .arm64: 0xB7
        case .x86_64: 0x3E
        }
    }
}

enum PluginError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case processFailed(String, Int32)
    case buildFailed(String)
    case invalidBinary(String)
    case toolchain(String)

    var description: String {
        switch self {
        // SwiftPM prefixes thrown plugin errors with "error: ".
        case .invalidArgument(let message): message
        case .processFailed(let command, let status): "`\(command)` failed with exit code \(status)"
        case .buildFailed(let message): message
        case .invalidBinary(let message): message
        case .toolchain(let message): message
        }
    }
}
