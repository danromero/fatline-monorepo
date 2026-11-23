import SwiftUI

/// The ways this app can reach Farcaster. Setup leads with a Neynar key.
enum ConnectionKind: CaseIterable, Hashable {
    case neynar, code, custom

    init(_ choice: ConnectionChoice) {
        switch choice {
        case .neynarKey: self = .neynar
        case .invite: self = .code
        case .custom: self = .custom
        }
    }

    fileprivate var setupTitle: String {
        switch self {
        case .neynar: "Connect to Farcaster"
        case .code: "Use a code"
        case .custom: "Connect your server"
        }
    }

    fileprivate var instruction: String {
        switch self {
        case .neynar: "Paste your Neynar API key."
        case .code: Invite.defaultServer == nil ? "Enter the code and server you were given." : "Enter the code you were given."
        case .custom: "Enter your server’s HTTPS base URL."
        }
    }

    fileprivate var switchLabel: String {
        switch self {
        case .neynar: "Neynar Key"
        case .code: "Code"
        case .custom: "Advanced"
        }
    }

    fileprivate var identifier: String {
        switch self {
        case .neynar: "connection-neynar"
        case .code: "connection-code"
        case .custom: "connection-custom"
        }
    }

    fileprivate var malformed: String {
        switch self {
        case .neynar: "Invalid key."
        case .code: Invite.defaultServer == nil ? "Use the format code@server.example." : "Invalid code."
        case .custom: "Enter an HTTPS URL."
        }
    }
}

/// The first screen: the portal, Fatline, and Continue.
struct WelcomeSplash: View {
    let session: PostingSession
    let next: () -> Void

    var body: some View {
        VStack(spacing: 16) { // layout-ok: the splash's mark, name and notice, unchanged since Welcome was approved
            Image("Portal")
                .resizable()
                .frame(width: 128, height: 128) // layout-ok: the splash's mark
                .clipShape(.rect(cornerRadius: 32)) // layout-ok: the splash's mark, a quarter of its side
                .accessibilityHidden(true)
            Text("Fatline")
                .font(FatlineStyle.display)
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            if let notice = session.notice {
                Text(notice)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, FatlineStyle.screenGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineBottomAction {
            Button {
                Platform.haptic(.tap)
                session.recoveryError = nil
                next()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(FatlinePrimaryButton())
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("welcome-continue")
        }
        .fatlineStepBar()
        .toolbarVisibilityForSplash()
    }
}

private extension View {
    /// The splash has nothing to put in iPhone's bar, so it doesn't take up the room.
    func toolbarVisibilityForSplash() -> some View {
        #if os(macOS)
        self
        #else
        toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/// For an account that signed in before there was a choice to make, and picks a connection once.
/// Back asks to start over, which forgets the sign-in and shows Welcome, so nobody is stuck here.
struct ConnectionSetup: View {
    /// The saved username, or the FID. Nil when nobody is signed in (a Mac Debug read-only feed).
    var signedInAs: String? = nil
    let finish: (ConnectionChoice) throws -> Void
    var startOver: (() throws -> Void)? = nil

    @State private var path: [ConnectionKind] = []

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionForm(setup: .neynar, saved: nil, signedInAs: signedInAs, startOver: startOver,
                           open: { path.append($0) }, finish: finish)
                .navigationDestination(for: ConnectionKind.self, destination: step)
        }
        .tint(FatlineStyle.action)
    }

    // Code and Advanced, pushed from the root, keep the system's own Back and get no line.
    private func step(_ kind: ConnectionKind) -> some View {
        ConnectionForm(setup: kind, saved: nil, open: { path.append($0) }, finish: finish)
    }
}

/// Puts in one way of reaching Farcaster: as a step of setup, or under Settings, where a switch at the
/// top picks which. A choice is only saved once a read through it has worked.
struct ConnectionForm: View {
    private static let fieldInset: CGFloat = 14
    private static let keyPage = URL(string: "https://dev.neynar.com")!
    private static let setupGuide = URL(string: "https://fatline.tech/custom-server.md")!
    /// The guide can change after this build ships, so the agent checks with the person before acting on it.
    private static let agentPrompt =
        "Read the instructions for setting up a Fatline custom server at \(setupGuide.absoluteString). Tell me what you plan to do and ask me before running any commands."

    /// Nil under Settings, where the switch moves between the ways to connect.
    private let open: ((ConnectionKind) -> Void)?
    private let saved: ConnectionChoice?
    private let finish: (ConnectionChoice) throws -> Void
    /// Only on `ConnectionSetup`'s first step: who's signed in, and what Back does once it's confirmed.
    private let signedInAs: String?
    private let startOver: (() throws -> Void)?

    @State private var kind: ConnectionKind
    @State private var code: String
    @State private var key: String
    @State private var address: String
    @State private var checking = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmingStartOver = false
    @State private var startOverError: String?
    @FocusState private var fieldFocused: Bool

    init(
        setup kind: ConnectionKind, saved: ConnectionChoice?, signedInAs: String? = nil,
        startOver: (() throws -> Void)? = nil,
        open: @escaping (ConnectionKind) -> Void, finish: @escaping (ConnectionChoice) throws -> Void
    ) {
        self.init(kind: kind, saved: saved, signedInAs: signedInAs, startOver: startOver, open: open, finish: finish)
    }

    init(settings saved: ConnectionChoice?, finish: @escaping (ConnectionChoice) throws -> Void) {
        self.init(kind: saved.map(ConnectionKind.init) ?? .neynar, saved: saved, signedInAs: nil, startOver: nil,
                  open: nil, finish: finish)
    }

    private init(
        kind: ConnectionKind, saved: ConnectionChoice?, signedInAs: String?, startOver: (() throws -> Void)?,
        open: ((ConnectionKind) -> Void)?, finish: @escaping (ConnectionChoice) throws -> Void
    ) {
        self.saved = saved
        self.open = open
        self.finish = finish
        self.signedInAs = signedInAs
        self.startOver = startOver
        var code = ""
        var key = ""
        var address = ""
        switch saved {
        case .invite(let savedInvite): code = savedInvite.text
        case .neynarKey(let savedKey): key = savedKey
        case .custom(let url): address = url.absoluteString
        case nil: break
        }
        _kind = State(initialValue: kind)
        _code = State(initialValue: code)
        _key = State(initialValue: key)
        _address = State(initialValue: address)
    }

    private var inSettings: Bool { open == nil }
    private var gutter: CGFloat { inSettings ? FatlineStyle.gutter : FatlineStyle.screenGutter }

    private var choice: ConnectionChoice? {
        switch kind {
        case .code: ConnectionChoice.invite(typed: code)
        case .neynar: ConnectionChoice.neynarKey(typed: key)
        case .custom: ConnectionChoice.custom(typed: address)
        }
    }

    private var hasInput: Bool {
        switch kind {
        case .code: !code.isEmpty
        case .neynar: !key.isEmpty
        case .custom: !address.isEmpty
        }
    }

    /// Settings has nothing to save until something differs from what's in use.
    private var canSubmit: Bool {
        hasInput && !checking && !(inSettings && choice == saved)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if inSettings {
                    Text("Connection").fatlineScreenTitle()
                    modeSwitch.padding(.top, 16) // layout-ok: Settings' title-to-switch gap
                    Text(kind.instruction)
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .padding(.top, 16) // layout-ok: Settings' switch-to-instruction gap
                    entry.padding(.top, FatlineStyle.itemGap)
                } else {
                    FatlineStepHeader(title: kind.setupTitle, instruction: kind.instruction)
                    entry.padding(.top, 20) // layout-ok: the setup steps' title-to-field gap
                    if let signedInAs {
                        Text("Signed in as \(Text(signedInAs).font(FatlineStyle.metaStrong).foregroundStyle(FatlineStyle.ink)) on this \(Platform.deviceName).")
                            .font(FatlineStyle.meta)
                            .foregroundStyle(FatlineStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, FatlineStyle.sectionGap)
                            .accessibilityIdentifier("connection-signed-in")
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.top, inSettings ? FatlineStyle.rowPadding : FatlineStyle.screenTop)
            .frame(maxWidth: FatlineStyle.columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .fatlineBottomAction(gutter: gutter) { action }
        .disabled(checking)
        .foregroundStyle(FatlineStyle.ink)
        .tint(FatlineStyle.action)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineStepBar()
        .toolbar {
            if let startOver {
                ToolbarItem(placement: .navigation) {
                    Button { confirmingStartOver = true } label: { Image(systemName: "chevron.left") }
                        .help("Back")
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("connection-start-over")
                        .keyboardShortcut(.cancelAction)
                        .disabled(checking)
                        // On the button, so iOS anchors the dialog to Back rather than the middle of the screen.
                        .confirmationDialog("Start over?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
                            Button("Start Over", role: .destructive) {
                                do { try startOver() } catch { startOverError = error.localizedDescription }
                            }
                        } message: {
                            Text("Fatline forgets \(signedInAs ?? "this account")’s sign-in on this \(Platform.deviceName). Your Farcaster account and casts aren’t touched.")
                        }
                }
            }
        }
        .alert("Couldn’t start over", isPresented: Binding(get: { startOverError != nil }, set: { if !$0 { startOverError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startOverError ?? "")
        }
        .navigationBarBackButtonHidden(checking)
        #if os(macOS)
        // There's a keyboard on hand, so the field is ready to paste into.
        .task { fieldFocused = true }
        #endif
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { copied = false }
        }
        .onChange(of: kind) { error = nil }
        .onChange(of: code) { error = nil }
        .onChange(of: key) { error = nil }
        .onChange(of: address) { error = nil }
        .onChange(of: error) { _, problem in
            if problem != nil { Platform.haptic(.problem) }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) { // layout-ok: the switch's 2-point inset, as the system's segmented control has
            ForEach(ConnectionKind.allCases, id: \.self) { option in
                Button { pick(option) } label: {
                    Text(option.switchLabel)
                        .font(FatlineStyle.metaStrong)
                        .foregroundStyle(kind == option ? FatlineStyle.ink : FatlineStyle.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: FatlineStyle.outlineButtonHeight - 4)
                        .background(kind == option ? FatlineStyle.paper : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == option ? .isSelected : [])
                .accessibilityIdentifier(option.identifier)
            }
        }
        .padding(2) // layout-ok: the switch's 2-point inset
        .background(FatlineStyle.quiet, in: .capsule)
    }

    private func pick(_ option: ConnectionKind) {
        if kind != option { Platform.haptic(.pick) }
        kind = option
        // Moving between two fields removes the one that had focus, so this waits for the new one.
        Task {
            fieldFocused = false
            await Task.yield()
            fieldFocused = true
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: FatlineStyle.itemGap) {
            field
            secondaryActions
            if let error {
                Text(error)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection-error")
            }
        }
    }

    private var field: some View {
        Group {
            switch kind {
            case .code:
                TextField("Code", text: $code, prompt: placeholder(Invite.defaultServer == nil ? "CODE@server.example" : "XXXX-XXXX-XXXX"))
                    #if os(iOS)
                    .keyboardType(Invite.defaultServer == nil ? .emailAddress : .asciiCapable)
                    .textInputAutocapitalization(Invite.defaultServer == nil ? .never : .characters)
                    #endif
                    .accessibilityLabel("Code")
            case .neynar:
                // Stays masked, even when it was filled in from the saved key.
                SecureField("API key", text: $key, prompt: placeholder("API key"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Neynar API key")
            case .custom:
                TextField("Server URL", text: $address, prompt: placeholder("https://example.com"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Server URL")
            }
        }
        .focused($fieldFocused)
        .autocorrectionDisabled()
        .font(FatlineStyle.body)
        .submitLabel(.done)
        #if os(macOS)
        .textFieldStyle(.plain)
        // The default button doesn't get Return while a text field has focus.
        .onSubmit(submit)
        #endif
        .padding(Self.fieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FatlineStyle.quiet, in: .rect(cornerRadius: FatlineStyle.fieldRadius))
        .accessibilityIdentifier("connection-field")
    }

    /// The same color as the recovery phrase's placeholder, which the system's default is paler than.
    private func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(FatlineStyle.secondary)
    }

    @ViewBuilder private var secondaryActions: some View {
        switch kind {
        case .neynar:
            if let open {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FatlineStyle.itemGap) { setupButtons(open) }
                    VStack(spacing: FatlineStyle.itemGap) { setupButtons(open) }
                }
            } else {
                getKeyLink(fills: false)
            }
        case .code:
            // A code names its own server, so show who it is before anything is sent there.
            if let invite = Invite(typed: code) {
                Text("Your reads and posts will go through \(invite.address).")
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection-invite-server")
            }
        case .custom:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FatlineStyle.itemGap) { agentButtons }
                VStack(spacing: FatlineStyle.itemGap) { agentButtons }
            }
        }
    }

    @ViewBuilder private func setupButtons(_ open: @escaping (ConnectionKind) -> Void) -> some View {
        getKeyLink(fills: true)
        Button("Use code") { go(to: .code, open) }
            .buttonStyle(FatlineOutlineButton(fills: true))
            .accessibilityIdentifier(ConnectionKind.code.identifier)
        Button("Advanced") { go(to: .custom, open) }
            .buttonStyle(FatlineOutlineButton(fills: true))
            .accessibilityIdentifier(ConnectionKind.custom.identifier)
    }

    private func go(to other: ConnectionKind, _ open: (ConnectionKind) -> Void) {
        Platform.haptic(.pick)
        fieldFocused = false
        error = nil
        open(other)
    }

    private func getKeyLink(fills: Bool) -> some View {
        Link(destination: Self.keyPage) { externalLabel("Get a key") }
            .buttonStyle(FatlineOutlineButton(fills: fills))
            .accessibilityHint("Opens in your browser")
            .accessibilityIdentifier("connection-get-key")
    }

    @ViewBuilder private var agentButtons: some View {
        Button {
            Platform.copyToClipboard(Self.agentPrompt)
            Platform.haptic(.tap)
            Platform.announce("Copied")
            copied = true
        } label: {
            HStack(spacing: 4) { // layout-ok: text to symbol, as in View setup guide beside it
                Text(copied ? "Copied" : "Copy agent prompt")
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(FatlineOutlineButton(fills: true))
        .accessibilityIdentifier("connection-copy-prompt")
        Link(destination: Self.setupGuide) { externalLabel("View setup guide") }
            .buttonStyle(FatlineOutlineButton(fills: true))
            .accessibilityHint("Opens in your browser")
            .accessibilityIdentifier("connection-setup-guide")
    }

    private func externalLabel(_ title: String) -> some View {
        HStack(spacing: 4) { // layout-ok: text to its arrow, tighter than a row of controls
            Text(title)
            Image(systemName: "arrow.up.right")
        }
    }

    private var action: some View {
        Button(action: submit) {
            Text(checking ? "Checking…" : inSettings ? "Save" : "Continue")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FatlinePrimaryButton(isWorking: checking))
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier("connection-continue")
    }

    private func submit() {
        guard canSubmit else { return }
        guard let choice else {
            error = kind.malformed
            return
        }
        Platform.haptic(.tap)
        fieldFocused = false
        error = nil
        // Nothing has changed, so there's nothing to check or spend credits on.
        guard choice != saved else {
            complete(choice)
            return
        }
        checking = true
        Task {
            let problem = await choice.problem()
            checking = false
            if let problem {
                error = problem
            } else {
                complete(choice)
            }
        }
    }

    private func complete(_ choice: ConnectionChoice) {
        do {
            try finish(choice)
        } catch {
            self.error = "Couldn’t save this on your device. Try again."
        }
    }
}
