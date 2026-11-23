import SwiftUI

/// Look Up tab: type a title, or enter a slab's cert number.
struct LookUpView: View {
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var certNumber = ""
    @State private var certCompany: GradingCompany = .cgc

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("e.g. Amazing Spider-Man #300", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit(lookUpTitle)
                    Button("Continue", action: lookUpTitle)
                        .disabled(query.trimmed.isEmpty)
                } header: {
                    Text("Raw or graded book")
                } footer: {
                    Text("Next you can add the variant, exclusive, signature and grade.")
                }

                Section {
                    Picker("Graded by", selection: $certCompany) {
                        Text("CGC").tag(GradingCompany.cgc)
                        Text("PSA").tag(GradingCompany.psa)
                    }
                    .pickerStyle(.segmented)
                    TextField("Cert number", text: $certNumber)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                    Button("Look up slab", action: lookUpCert)
                        .disabled(certNumber.filter(\.isNumber).count < 6)
                } header: {
                    Text("Slab cert number")
                } footer: {
                    Text("Or point the Scan tab at the QR code on the slab label.")
                }
            }
            .navigationTitle("Look Up")
            .comicDestinations()
            .environment(\.popToRoot, PopToRoot { path = NavigationPath() })
        }
    }

    private func lookUpTitle() {
        guard !query.trimmed.isEmpty else { return }
        path.append(Route.spec(ComicSpec(searchText: query)))
    }

    private func lookUpCert() {
        path.append(Route.cert(SlabCert(company: certCompany, number: certNumber.filter(\.isNumber))))
    }
}

/// The details that set the price: title, issue, variant, exclusive, printing, signature, grade.
struct SpecEditorView: View {
    let source: Route

    @Environment(WebBot.self) private var bot
    @State private var spec = ComicSpec()
    @State private var started = false
    @State private var loadingMessage: String?
    @State private var problem: String?
    @State private var titleSuggestions: [String] = []
    @State private var certFields: [(String, String)] = []
    @State private var editingQuery = false

    static let grades: [Double] = [10, 9.9, 9.8, 9.6, 9.4, 9.2, 9.0, 8.5, 8.0, 7.5, 7.0, 6.5, 6.0, 5.5, 5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0, 1.8, 1.5, 1.0, 0.5]

    var body: some View {
        Form {
            if let loadingMessage {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text(loadingMessage)
                            if !bot.status.isEmpty {
                                Text(bot.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if case .cert(let cert) = source, let url = cert.lookupURL {
                        Button("Open the cert page") {
                            bot.show(url, message: "Here's the cert page. Copy the details into the form.")
                        }
                    }
                }
            }

            if !titleSuggestions.isEmpty {
                Section {
                    ForEach(titleSuggestions, id: \.self) { suggestion in
                        Button {
                            spec.title = EbaySoldSearch.seriesGuess(from: suggestion, issue: spec.issue)
                            titleSuggestions = []
                        } label: {
                            Text(suggestion).foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Listings with this barcode")
                } footer: {
                    Text("Tap the one that matches your book to fill in the title.")
                }
            }

            bookSection
            coverSection
            signatureSection
            gradingSection

            if !spec.notes.isEmpty {
                Section("Notes") {
                    Text(spec.notes).font(.callout)
                }
            }

            if !certFields.isEmpty {
                Section {
                    DisclosureGroup("What the cert page says") {
                        ForEach(Array(certFields.enumerated()), id: \.offset) { _, field in
                            LabeledContent(field.0, value: field.1)
                                .font(.caption)
                        }
                    }
                }
            }

            searchSection
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
    }

    // MARK: Sections

    private var bookSection: some View {
        Section("Book") {
            TextField("Series title", text: $spec.title)
                .autocorrectionDisabled()
            TextField("Issue #", text: $spec.issue)
                .keyboardType(.numbersAndPunctuation)
            TextField("Year (optional)", text: $spec.year)
                .keyboardType(.numberPad)
            TextField("Publisher (optional)", text: $spec.publisher)
        }
    }

    private var coverSection: some View {
        Section {
            TextField("Variant (e.g. Cover B, Virgin 1:25, Campbell)", text: $spec.variant)
                .autocorrectionDisabled()
            TextField("Exclusive (e.g. Mile High, SDCC)", text: $spec.exclusive)
                .autocorrectionDisabled()
            Stepper("\(ordinal(spec.printing)) printing", value: $spec.printing, in: 1...10)
        } header: {
            Text("Cover")
        } footer: {
            Text("Leave Variant and Exclusive blank for the regular cover. Sales of other covers are left out.")
        }
    }

    private var signatureSection: some View {
        Section("Signature") {
            Toggle("Signed", isOn: $spec.signed.animation())
            if spec.signed {
                TextField("Signed by", text: $spec.signer)
                    .textContentType(.name)
                if !spec.graded {
                    Picker("Proof", selection: $spec.signatureProof) {
                        ForEach(SignatureProof.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
        }
    }

    private var gradingSection: some View {
        Section {
            Toggle("Graded (slabbed)", isOn: $spec.graded.animation())
            if spec.graded {
                Picker("Company", selection: $spec.company) {
                    ForEach(GradingCompany.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Grade", selection: $spec.grade) {
                    ForEach(gradeOptions, id: \.self) { grade in
                        Text(grade >= 10 ? "10" : String(format: "%.1f", grade)).tag(grade)
                    }
                }
                Picker("Label", selection: $spec.label) {
                    ForEach(SlabLabel.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Page quality (optional)", text: $spec.pageQuality)
                TextField("Cert # (optional)", text: $spec.certNumber)
                    .keyboardType(.numberPad)
            }
        } header: {
            Text("Grading")
        } footer: {
            if spec.graded {
                Text("Only sales of the same company and exact grade are counted. Signature Series and Qualified/Restored labels are kept apart.")
            }
        }
    }

    private var searchSection: some View {
        Section {
            NavigationLink(value: Route.comps(spec)) {
                Label("Find sold prices on eBay", systemImage: "dollarsign.circle.fill")
                    .font(.headline)
            }
            .disabled(spec.isEmpty)

            DisclosureGroup("eBay search words", isExpanded: $editingQuery) {
                TextField("Search words", text: queryBinding, axis: .vertical)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !spec.customQuery.isEmpty {
                    Button("Reset to automatic") { spec.customQuery = "" }
                }
            }
        } footer: {
            Text("Words starting with - are excluded. The app also checks every sale's title against the details above.")
        }
    }

    // MARK: Helpers

    private var gradeOptions: [Double] {
        Self.grades.contains(spec.grade) ? Self.grades : (Self.grades + [spec.grade]).sorted(by: >)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { spec.ebayQuery },
            set: { spec.customQuery = $0 }
        )
    }

    private var navigationTitle: String {
        switch source {
        case .cert(let cert): return "\(cert.company.rawValue) \(cert.number)"
        case .barcode: return "Scanned comic"
        default: return spec.title.isEmpty ? "Comic details" : spec.displayTitle
        }
    }

    private func start() async {
        guard !started else { return }
        started = true

        switch source {
        case .spec(let initial):
            spec = initial
            SoldCache.shared.prefetch(for: spec, seed: [], bot: bot)

        case .barcode(let barcode):
            spec = barcode.spec
            loadingMessage = "Looking up this barcode on eBay…"
            do {
                titleSuggestions = try await EbaySoldSearch.titlesForBarcode(barcode, bot: bot)
                if titleSuggestions.isEmpty {
                    problem = "No eBay listings mention this barcode. Type the title below."
                }
            } catch {
                if !error.isCancellation { problem = error.localizedDescription }
            }
            loadingMessage = nil

        case .cert(let cert):
            spec.graded = true
            spec.company = cert.company
            spec.certNumber = cert.number
            guard cert.lookupURL != nil else {
                problem = "\(cert.company.rawValue) certs can't be read automatically. Fill in the details from the label."
                return
            }
            loadingMessage = "Reading the \(cert.company.rawValue) cert page…"
            do {
                let result = try await CertLookup.lookUp(cert, bot: bot)
                spec = result.spec
                certFields = result.fields
                if spec.title.isEmpty {
                    problem = "Couldn't read the title from the cert page. Check the details below."
                } else {
                    SoldCache.shared.prefetch(for: spec, seed: [], bot: bot)
                }
            } catch {
                if !error.isCancellation { problem = error.localizedDescription }
            }
            loadingMessage = nil

        case .comps(let initial):
            spec = initial
        }
    }
}
