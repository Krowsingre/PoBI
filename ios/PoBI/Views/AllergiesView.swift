import SwiftUI

struct AllergiesView: View {
    @EnvironmentObject private var allergies: AllergyStore
    @State private var newAllergy = ""

    var body: some View {
        Form {
            Section {
                ForEach(AllergyStore.common, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { allergies.selected.contains(name) },
                        set: { on in
                            if on { allergies.selected.insert(name) } else { allergies.selected.remove(name) }
                        }
                    ))
                }
            } header: {
                Text("Common allergies")
            }

            Section {
                ForEach(allergies.custom, id: \.self) { name in
                    Text(name)
                }
                .onDelete { allergies.custom.remove(atOffsets: $0) }
                HStack {
                    TextField("Add another, like mustard", text: $newAllergy)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newAllergy.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Other allergies")
            } footer: {
                Text("Swipe left on one to remove it.")
            }

            Section {
                TextField("For example, how severe a reaction is", text: $allergies.notes, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("Notes")
            } footer: {
                Text("Your allergies stay on this phone. They show on each place's page as a reminder. Always tell staff before you order.")
            }
        }
        .navigationTitle("My allergies")
    }

    private func add() {
        allergies.addCustom(newAllergy)
        newAllergy = ""
    }
}

/// A reminder of your allergies on a place's page.
struct AllergyReminder: View {
    @EnvironmentObject private var allergies: AllergyStore

    var body: some View {
        if !allergies.isEmpty {
            Section {
                if !allergies.all.isEmpty {
                    Label(allergies.all.joined(separator: ", "), systemImage: "allergens")
                }
                let notes = allergies.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty {
                    Text(notes).foregroundStyle(.secondary)
                }
            } header: {
                Text("Your allergies")
            } footer: {
                Text("This place's own allergy information isn't in the app yet. Tell staff before you order.")
            }
        }
    }
}
