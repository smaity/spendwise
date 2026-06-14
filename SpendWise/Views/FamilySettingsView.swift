// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Edit the app owner's own details — name and any aliases/UPI handles.
struct ProfileEditorView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile

    init(profile: UserProfile) { _profile = State(initialValue: profile) }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $profile.name)
                TextField("Other names / UPI handles (optional)", text: $profile.aliases)
            } footer: {
                Text("Helps Apple Intelligence understand who you are — for example, so transfers to your own accounts aren't counted as money sent to family.")
            }
            Section {
                TextField("e.g. 4821, 1166, 9043", text: $profile.accounts)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Your accounts")
            } footer: {
                Text("Last 4 digits of each of your own bank accounts, separated by commas. Transfers between them are tagged “Own account” so you can tell them apart from real spending.")
            }
        }
        .navigationTitle("Your details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { store.updateUserProfile(profile); dismiss() }
            }
        }
    }
}

/// Add or edit a single family member's details.
struct FamilyMemberEditorView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss
    @State private var member: FamilyMember
    let isNew: Bool

    init(member: FamilyMember, isNew: Bool) {
        _member = State(initialValue: member)
        self.isNew = isNew
    }

    private var canSave: Bool { !member.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $member.name)
                TextField("Relationship (e.g. Mother)", text: $member.relationship)
                TextField("Nicknames / UPI handles (optional)", text: $member.aliases)
                TextField("Account number — last 4 digits (optional)", text: $member.accountLast4)
                    .keyboardType(.numberPad)
            } footer: {
                Text("The more detail you add, the better transfers are matched. The account's last 4 digits give an exact match — even when the bank alert shows no name. Nicknames (e.g. \"Mummy\"), short names, and UPI handles also help.")
            }
            if !isNew {
                Section {
                    Button("Remove family member", role: .destructive) {
                        store.removeFamilyMember(member); dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add family member" : member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { store.upsertFamilyMember(member); dismiss() }
                    .disabled(!canSave)
            }
        }
    }
}
