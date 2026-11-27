import SwiftUI
import UniformTypeIdentifiers

struct RootfsRecipe: Codable, Equatable {
    var schemaVersion = 1
    var name = "Alpine iSH-AOK"
    var distribution = "Alpine"
    var release = "v3.24"
    var architecture = "aarch64"
    var packages = ""
    var packageProfiles: [String] = ["core", "editors"]
    var initSystem = "OpenRC"
    var includeSSH = false
    var enableCron = false
    var enableNginx = false
    var sshPort = 22
    var hostname = "ish-aok"
    var timezone = "UTC"
    var dns = "1.1.1.1, 8.8.8.8"
    var locale = "C.UTF-8"
    var username = ""
    var userShell = "/bin/sh"
    var userSudo = false
    var defaultEditor = "nano"
    var compression = "gzip"

    var packageList: [String] {
        packages.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, name, distribution, release, architecture, packages, packageProfiles, initSystem
        case includeSSH, enableCron, enableNginx, sshPort, hostname, timezone, dns, locale, username, userShell, userSudo, defaultEditor, compression
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Alpine iSH-AOK"
        distribution = try c.decodeIfPresent(String.self, forKey: .distribution) ?? "Alpine"
        release = try c.decodeIfPresent(String.self, forKey: .release) ?? "v3.24"
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? "aarch64"
        packages = try c.decodeIfPresent(String.self, forKey: .packages) ?? ""
        packageProfiles = try c.decodeIfPresent([String].self, forKey: .packageProfiles) ?? ["core", "editors"]
        initSystem = try c.decodeIfPresent(String.self, forKey: .initSystem) ?? "OpenRC"
        includeSSH = try c.decodeIfPresent(Bool.self, forKey: .includeSSH) ?? false
        enableCron = try c.decodeIfPresent(Bool.self, forKey: .enableCron) ?? false
        enableNginx = try c.decodeIfPresent(Bool.self, forKey: .enableNginx) ?? false
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? "ish-aok"
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
        dns = try c.decodeIfPresent(String.self, forKey: .dns) ?? "1.1.1.1, 8.8.8.8"
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "C.UTF-8"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        userShell = try c.decodeIfPresent(String.self, forKey: .userShell) ?? "/bin/sh"
        userSudo = try c.decodeIfPresent(Bool.self, forKey: .userSudo) ?? false
        defaultEditor = try c.decodeIfPresent(String.self, forKey: .defaultEditor) ?? "nano"
        compression = try c.decodeIfPresent(String.self, forKey: .compression) ?? "gzip"
    }
}

struct PackageProfile: Identifiable {
    let key: String
    let title: String
    let detail: String
    var id: String { key }
}

struct ContentView: View {
    @State private var recipe = RootfsRecipe()
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let distributions = ["Debian", "Devuan", "Ubuntu", "Alpine", "Arch Linux ARM", "Fedora", "Kali Linux", "openSUSE Leap", "openSUSE Tumbleweed", "Gentoo", "Void Linux"]
    private let compressionTypes = ["gzip", "xz"]
    private let profiles: [PackageProfile] = [
        PackageProfile(key: "core", title: "Core CLI", detail: "bash, curl, wget, network and process tools"),
        PackageProfile(key: "editors", title: "Editors", detail: "nano and vim"),
        PackageProfile(key: "developer", title: "Developer", detail: "Git, compiler, build tools and debuggers"),
        PackageProfile(key: "languages", title: "Languages", detail: "Python, Node.js, Go and Rust"),
        PackageProfile(key: "network", title: "Network diagnostics", detail: "DNS, ping, nmap, tcpdump and traceroute"),
        PackageProfile(key: "server", title: "Server", detail: "sudo, logging, cron, time sync and nftables"),
        PackageProfile(key: "web", title: "Web services", detail: "nginx and database clients"),
        PackageProfile(key: "security", title: "Security tools", detail: "GnuPG, OpenSSL and packet tools"),
        PackageProfile(key: "storage", title: "Storage", detail: "rsync, archives, filesystems and partition tools"),
        PackageProfile(key: "terminal", title: "Terminal utilities", detail: "tmux, screen, htop, jq, tree and ncdu")
    ]

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
                Section("Distribution and release") {
                    TextField("Rootfs name", text: $recipe.name)
                    Picker("Distribution", selection: $recipe.distribution) { ForEach(distributions, id: \.self) { Text($0) } }
                    Picker("Release", selection: $recipe.release) { ForEach(releases, id: \.self) { Text($0) } }
                    LabeledContent("Architecture", value: "ARM64 / aarch64")
                    Picker("Init system", selection: $recipe.initSystem) { ForEach(initSystems, id: \.self) { Text($0) } }
                }
                Section("Systui package profiles") {
                    ForEach(profiles) { profile in
                        Toggle(isOn: profileBinding(profile.key)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.title)
                                Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TextField("Additional native package names", text: $recipe.packages, axis: .vertical).lineLimit(2...5)
                    Text("Profiles are mapped to each distro’s package names; manual entries are passed directly to its package manager.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Services") {
                    Toggle("Install and enable OpenSSH server", isOn: $recipe.includeSSH)
                    Toggle("Enable cron service", isOn: $recipe.enableCron)
                    Toggle("Install and enable nginx", isOn: $recipe.enableNginx)
                    if recipe.includeSSH {
                        Stepper("SSH port: \(recipe.sshPort)", value: $recipe.sshPort, in: 1...65535)
                        Text("Root SSH uses key authentication; configure authorized keys after importing.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Accounts and shell") {
                    TextField("Optional username", text: $recipe.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Login shell", selection: $recipe.userShell) {
                        Text("System shell (/bin/sh)").tag("/bin/sh")
                        Text("Bash").tag("/bin/bash")
                        Text("Zsh").tag("/bin/zsh")
                        Text("Fish").tag("/usr/bin/fish")
                    }
                    Toggle("Add user to sudo/wheel group", isOn: $recipe.userSudo)
                    Picker("Default editor", selection: $recipe.defaultEditor) {
                        Text("None").tag("none")
                        Text("Nano").tag("nano")
                        Text("Vim").tag("vim")
                        Text("Neovim").tag("neovim")
                        Text("Micro").tag("micro")
                    }
                    Text("New accounts have no password set. Set one from a root session after import.").font(.caption).foregroundStyle(.secondary)
                }
                Section("System configuration") {
                    TextField("Hostname", text: $recipe.hostname).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Timezone (e.g. America/New_York)", text: $recipe.timezone).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("DNS resolver IPs, comma-separated", text: $recipe.dns).keyboardType(.default).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Locale", selection: $recipe.locale) {
                        Text("C.UTF-8 (portable)").tag("C.UTF-8")
                        Text("English (US) UTF-8").tag("en_US.UTF-8")
                    }
                }
                Section("Archive and summary") {
                    Picker("Compression", selection: $recipe.compression) { ForEach(compressionTypes, id: \.self) { Text($0) } }
                    LabeledContent("Output", value: recipe.compression == "gzip" ? ".tar.gz" : ".tar.xz")
                    LabeledContent("Package profiles", value: "\(recipe.packageProfiles.count)")
                    LabeledContent("Manual packages", value: "\(recipe.packageList.count)")
                    Button { exportRecipe() } label: { Label("Export recipe JSON", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import recipe JSON", systemImage: "square.and.arrow.down") }
                }
                Section("Build with GitHub Actions") {
                    Text("Commit the exported JSON under recipes/ in the GitHub repository, then run Actions → Build rootfs tarball. Download the workflow artifact and import it in iSH-AOK.").font(.caption)
                    Text("Bedrock Linux is a meta-distribution requiring an existing base and FUSE hijack; it is not a standalone builder target.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Systui Rootfs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Export recipe") { exportRecipe() }
                        Button("Import recipe") { showImporter = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { loadDraft() }
            .onChange(of: recipe) { _ in saveDraft() }
            .onChange(of: recipe.distribution) { newValue in updateDefaults(for: newValue) }
            .fileExporter(isPresented: $showExporter, document: RecipeDocument(data: recipeData()), contentType: .json, defaultFilename: safeName + "-recipe") { result in
                if case .failure(let error) = result { present(error) }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    recipe = try JSONDecoder().decode(RootfsRecipe.self, from: Data(contentsOf: url))
                } catch { present(error) }
            }
            .alert("Recipe error", isPresented: $showError) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private func profileBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { recipe.packageProfiles.contains(key) }, set: { enabled in
            if enabled && !recipe.packageProfiles.contains(key) { recipe.packageProfiles.append(key) }
            if !enabled { recipe.packageProfiles.removeAll { $0 == key } }
        })
    }

    private func updateDefaults(for distribution: String) {
        if let first = releases.first { recipe.release = first }
        switch distribution {
        case "Alpine": recipe.initSystem = "OpenRC"
        case "Devuan": recipe.initSystem = "SysVinit"
        case "Void Linux": recipe.initSystem = "runit"
        case "Gentoo": recipe.initSystem = "OpenRC"
        default: recipe.initSystem = "systemd"
        }
        recipe.packages = ""
    }

    private var safeName: String { recipe.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-") }
    private func recipeData() -> Data { (try? JSONEncoder.pretty.encode(recipe)) ?? Data("{}".utf8) }
    private func exportRecipe() { showExporter = true }
    private func present(_ error: Error) { errorMessage = error.localizedDescription; showError = true }
    private func saveDraft() { if let data = try? JSONEncoder().encode(recipe) { UserDefaults.standard.set(data, forKey: "rootfsDraft") } }
    private func loadDraft() { if let data = UserDefaults.standard.data(forKey: "rootfsDraft"), let saved = try? JSONDecoder().decode(RootfsRecipe.self, from: data) { recipe = saved } }
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
