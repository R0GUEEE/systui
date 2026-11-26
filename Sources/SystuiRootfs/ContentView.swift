import SwiftUI
import UniformTypeIdentifiers

struct RootfsRecipe: Codable {
    var schemaVersion = 1
    var name = "Alpine iSH-AOK"
    var distribution = "Alpine"
    var release = "v3.23"
    var architecture = "aarch64"
    var packages = "ca-certificates, curl"
    var initSystem = "OpenRC"
    var includeSSH = false
    var hostname = "ish-aok"
    var timezone = "UTC"
    var dns = "1.1.1.1"
    var compression = "gzip"

    var packageList: [String] {
        packages.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct DistroOption: Identifiable {
    let title: String
    var id: String { title }
}

struct ContentView: View {
    @State private var recipe = RootfsRecipe()
    @State private var showExporter = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let distributions = ["Debian", "Devuan", "Ubuntu", "Alpine", "Arch Linux ARM", "Fedora", "Kali Linux", "openSUSE Leap", "openSUSE Tumbleweed", "Gentoo", "Void Linux"]
    private let compressionTypes = ["gzip", "xz"]

    private var releases: [String] {
        switch recipe.distribution {
        case "Debian": ["trixie", "bookworm"]
        case "Devuan": ["excalibur", "daedalus"]
        case "Ubuntu": ["24.04", "22.04"]
        case "Alpine": ["v3.24", "v3.23", "v3.22", "edge"]
        case "Arch Linux ARM", "Void Linux", "openSUSE Tumbleweed", "Gentoo", "Kali Linux": ["rolling"]
        case "Fedora": ["45", "44"]
        case "openSUSE Leap": ["16.0", "15.6"]
        default: []
        }
    }

    private var initSystems: [String] {
        switch recipe.distribution {
        case "Alpine": ["OpenRC"]
        case "Devuan": ["SysVinit", "runit"]
        case "Void Linux": ["runit"]
        case "Gentoo": ["OpenRC", "systemd"]
        case "Arch Linux ARM": ["systemd", "runit"]
        case "Fedora", "openSUSE Leap", "openSUSE Tumbleweed": ["systemd"]
        default: ["systemd", "SysVinit"]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Distribution") {
                    TextField("Rootfs name", text: $recipe.name)
                    Picker("Distribution", selection: $recipe.distribution) {
                        ForEach(distributions, id: \.self) { Text($0) }
                    }
                    Picker("Release", selection: $recipe.release) {
                        ForEach(releases, id: \.self) { Text($0) }
                    }
                    LabeledContent("Target architecture", value: "ARM64 / aarch64")
                    Picker("Init system", selection: $recipe.initSystem) {
                        ForEach(initSystems, id: \.self) { Text($0) }
                    }
                }
                Section("Packages and services") {
                    TextField("Packages (comma-separated)", text: $recipe.packages, axis: .vertical).lineLimit(2...5)
                    Toggle("Include OpenSSH server", isOn: $recipe.includeSSH)
                    Text("Package names are passed to the selected distribution’s native package manager.").font(.caption).foregroundStyle(.secondary)
                }
                Section("System configuration") {
                    TextField("Hostname", text: $recipe.hostname)
                    TextField("Timezone", text: $recipe.timezone).textInputAutocapitalization(.never)
                    TextField("DNS resolver", text: $recipe.dns).keyboardType(.decimalPad)
                }
                Section("Archive") {
                    Picker("Compression", selection: $recipe.compression) { ForEach(compressionTypes, id: \.self) { Text($0) } }
                    LabeledContent("Output", value: recipe.compression == "gzip" ? ".tar.gz" : ".tar.xz")
                }
                Section("Build recipe") {
                    LabeledContent("Packages", value: "\(recipe.packageList.count)")
                    LabeledContent("Build target", value: "\(recipe.distribution) · aarch64")
                    Button { exportRecipe() } label: { Label("Export recipe JSON", systemImage: "square.and.arrow.up") }
                    Text("Bedrock Linux is a meta-distribution that requires a base distribution and FUSE hijack; it is not a standalone target in this builder.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Create and import") {
                    Text("Export the recipe, add it under recipes/ in the GitHub repository, then run Actions → Build rootfs tarball. Download the artifact and import it using iSH-AOK’s rootfs import flow.").font(.caption)
                    Text("Build support: Debian, Devuan, Ubuntu, Alpine, Arch Linux ARM, Fedora, Kali, openSUSE Leap/Tumbleweed, Gentoo and Void. Builds target ARM64; default repositories and current distro package metadata are used.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Systui Rootfs")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Export") { exportRecipe() } } }
            .onChange(of: recipe.distribution) { newValue in
                if let first = releases.first { recipe.release = first }
                switch newValue {
                case "Alpine": recipe.initSystem = "OpenRC"
                case "Devuan": recipe.initSystem = "SysVinit"
                case "Void Linux": recipe.initSystem = "runit"
                case "Gentoo": recipe.initSystem = "OpenRC"
                default: recipe.initSystem = "systemd"
                }
                recipe.packages = newValue == "Gentoo" ? "app-misc/ca-certificates, net-misc/curl" : "ca-certificates, curl"
            }
            .fileExporter(isPresented: $showExporter, document: RecipeDocument(data: recipeData()), contentType: .json, defaultFilename: safeName + "-recipe") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription; showError = true }
            }
            .alert("Export failed", isPresented: $showError) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private var safeName: String { recipe.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-") }
    private func recipeData() -> Data { (try? JSONEncoder.pretty.encode(recipe)) ?? Data("{}".utf8) }
    private func exportRecipe() { showExporter = true }
}

struct RecipeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
