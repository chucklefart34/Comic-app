import SwiftData
import SwiftUI

/// Correct the identification by hand: edition, printing, signature, slab, codes.
struct EditComicView: View {
    @Bindable var record: ComicRecord
    var onSaved: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var spec = ComicSpec()
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Comic") {
                TextField("Series title", text: $spec.title).autocorrectionDisabled()
                TextField("Issue #", text: $spec.issue).keyboardType(.numbersAndPunctuation)
                TextField("Publisher", text: $spec.publisher)
                TextField("Year", text: $spec.year).keyboardType(.numberPad)
                TextField("Volume", text: $spec.volume)
            }
            Section {
                TextField("Variant (e.g. Cover B, Virgin 1:25)", text: $spec.variant).autocorrectionDisabled()
                TextField("Exclusive (e.g. Mile High, SDCC)", text: $spec.exclusive).autocorrectionDisabled()
                Stepper("\(ordinal(spec.printing)) printing", value: $spec.printing, in: 1...10)
                Picker("Edition", selection: $spec.printEdition) {
                    ForEach(PrintEdition.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Reprint / facsimile", isOn: $spec.isReprint)
            } header: {
                Text("Edition")
            } footer: {
                Text("Leave Variant blank for the regular cover. Sales of other covers and printings are left out of the price.")
            }
            Section("Credits") {
                TextField("Writer", text: $spec.writer)
                TextField("Cover artist", text: $spec.coverArtist)
            }
            Section("Signature") {
                Toggle("Signed", isOn: $spec.signed.animation())
                if spec.signed {
                    TextField("Signed by", text: $spec.signer)
                    Picker("Proof", selection: $spec.signatureProof) {
                        ForEach(SignatureProof.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            Section("Slab") {
                Toggle("Graded (slabbed)", isOn: $spec.graded.animation())
                if spec.graded {
                    Picker("Company", selection: $spec.company) {
                        ForEach(GradingCompany.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Grade", selection: $spec.grade) {
                        ForEach(standardGrades, id: \.self) { Text(gradeLabel($0)).tag($0) }
                    }
                    Picker("Label", selection: $spec.label) {
                        ForEach(SlabLabel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Cert #", text: $spec.certNumber).keyboardType(.numberPad)
                }
            }
            Section("Codes") {
                TextField("UPC", text: $spec.upc).keyboardType(.numberPad)
                TextField("ISBN", text: $spec.isbn).keyboardType(.numberPad)
            }
            Section {
                TextField("eBay search words (optional)", text: $spec.customQuery, axis: .vertical)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Only if the automatic search keeps missing. Words starting with - are excluded.")
            }
        }
        .navigationTitle("Edit comic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(spec.title.trimmed.isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            spec = record.spec
            loaded = true
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let before = record.spec
        record.update(spec: spec)
        if spec.graded && !before.graded { record.condition = .graded }
        // Remember the correction for the next scan of this barcode / cover.
        if before.editionKey != spec.editionKey || before.upc != spec.upc {
            Identifier.remember(Candidate(spec: spec, imageURL: record.imageURL, source: "You"), from: nil, context: modelContext)
        }
        if PricingService.cacheKey(before) != PricingService.cacheKey(spec) { onSaved() }
        dismiss()
    }
}
