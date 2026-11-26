import SwiftUI
import UniformTypeIdentifiers

struct RootfsRecipe: Codable {
    var schemaVersion = 1
    var name = "Alpine iSH-AOK"
    var distribution = "Alpine"
    var release = "latest-stable"
    var architecture = "aarch64"
    var packages = "alpine-base, busybox, ca-certificates"
    var initSystem = "OpenRC"
    var includeSSH = false
    var compression = "gzip"

    var packageList: [String] {
        packages.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct ContentView: View {
    @State private var recipe = RootfsRecipe()
    @State private var showExporter = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let distributions = ["Alpine", "Debian", "Ubuntu", "Devuan", "Arch Linux", "Void Linux"]
    private let architectures = ["aarch64"]
    private let initSystems = ["OpenRC", "BusyBox init", "runit", "systemd"]
    private let compressionTypes = ["gzip", "xz"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Root filesystem") {
                    TextField("Recipe name", text: $recipe.name)
                    Picker("Distribution", selection: $recipe.distribution) { ForEach(distributions, id: \.self) { Text($0) } }
                    TextField("Release / suite", text: $recipe.release)
                    Picker("Architecture", selection: $recipe.architecture) { ForEach(architectures, id: \.self) { Text($0) } }
                    Picker("Init system", selection: $recipe.initSystem) { ForEach(initSystems, id: \.self) { Text($0) } }
                }
                Section("Packages and access") {
                    TextField("Comma-separated package names", text: $recipe.packages, axis: .vertical).lineLimit(2...5)
                    Toggle("Include OpenSSH server", isOn: $recipe.includeSSH)
                }
                Section("Archive") {
                    Picker("Compression", selection: $recipe.compression) { ForEach(compressionTypes, id: \.self) { Text($0) } }
                    LabeledContent("Format", value: recipe.compression == "gzip" ? ".tar.gz" : ".tar.xz")
                }
                Section("Recipe summary") {
                    LabeledContent("Packages", value: "\(recipe.packageList.count)")
                    LabeledContent("Target", value: "\(recipe.distribution) · \(recipe.architecture)")
                    Button { exportRecipe() } label: { Label("Export build recipe JSON", systemImage: "square.and.arrow.up") }
                }
                Section("Build and import") {
                    Label("Build a supported Alpine recipe in GitHub Actions.", systemImage: "server.rack")
                    Text("Export the recipe JSON, add it under recipes/ in this repository, then run Actions → Build rootfs tarball. Download the resulting artifact and import that tarball in iSH-AOK.").font(.caption).foregroundStyle(.secondary)
                    Text("The first builder supports Alpine on aarch64, armv7, and x86_64 with OpenRC. The generated tarball is a minimal Alpine root, not a complete replacement for Systui’s full distro-specific configuration yet.").font(.caption)
                }
            }
            .navigationTitle("Systui Rootfs")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Export") { exportRecipe() } } }
            .fileExporter(isPresented: $showExporter, document: RecipeDocument(data: recipeData()), contentType: .json, defaultFilename: safeName + "-recipe") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription; showError = true }
            }
            .alert("Export failed", isPresented: $showError) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private var safeName: String { recipe.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.split(separator: "-").map(String.init).joined(separator: "-") }
    private func recipeData() -> Data { (try? JSONEncoder.pretty.encode(recipe)) ?? Data("{}".utf8) }
    private func exportRecipe() { showExporter = true }
}

struct RecipeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { return FileWrapper(regularFileWithContents: data) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
