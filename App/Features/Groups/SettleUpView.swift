import SwiftUI
import TABCore

/// One suggested payment: how to make it in the app the two people already use, and a way to record that it
/// was made. TAB never moves money.
struct SettleUpView: View {
    let group: ExpenseGroup
    let settlement: Settlement
    let from: String
    let to: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var handles = PaymentHandles()
    @State private var editing = false
    @State private var copied: String?
    @State private var message: String?
    @State private var working = false

    private var amount: String { group.currency.format(minorUnits: settlement.amountMinor) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 6) {
                        Text("\(from) pays \(to)").font(.headline).foregroundStyle(.secondary)
                        Text(amount)
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            .accessibilityIdentifier("settleAmount")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    CardSection("Pay \(to)") {
                        if let url = PaymentLinks.payPal(handle: handles.payPalMe ?? "", amountMinor: settlement.amountMinor, currency: group.currency) {
                            Button { openURL(url) } label: { row("Open PayPal", systemImage: "arrow.up.right.square") }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("openPayPal")
                            Divider().padding(.leading, 56)
                        }
                        if let url = PaymentLinks.revolut(tag: handles.revolutTag ?? "") {
                            Button { openURL(url) } label: { row("Open Revolut", systemImage: "arrow.up.right.square") }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("openRevolut")
                            Divider().padding(.leading, 56)
                        }
                        if let phone = handles.bizumPhone, !phone.isEmpty {
                            Button { copy(phone, label: String(localized: "Bizum number copied")) } label: {
                                row("Copy Bizum number", systemImage: "doc.on.doc", detail: phone)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("copyBizum")
                            Divider().padding(.leading, 56)
                        }
                        if let iban = handles.iban.flatMap(PaymentLinks.normalizedIBAN) {
                            Button { copy(iban, label: String(localized: "IBAN copied")) } label: {
                                row("Copy IBAN", systemImage: "doc.on.doc", detail: PaymentLinks.spacedIBAN(iban))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("copyIBAN")
                            Divider().padding(.leading, 56)
                        }
                        Button { editing = true } label: {
                            row(handles.isEmpty ? "Add how to pay \(to)" : "Edit how to pay \(to)", systemImage: "pencil")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editPaymentDetails")
                    }
                    if let copied {
                        Text(copied).font(.footnote).foregroundStyle(Theme.positive).padding(.horizontal, 4)
                    }
                    Text("TAB opens the app or copies the details. The payment is made there, never in TAB. These details stay on this iPhone and are not shared with the group.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.negative).padding(.horizontal, 4)
                    }
                    Button("Mark as paid", action: markAsPaid)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working)
                        .accessibilityIdentifier("markAsPaid")
                    Text("Adds a payment of \(amount) from \(from) to \(to), so the balances update.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationDestination(isPresented: $editing) {
                PaymentDetailsForm(name: to, handles: $handles) { model.setPaymentHandles(handles, for: settlement.to) }
            }
            .onAppear { handles = model.paymentHandles(for: settlement.to) }
        }
        .tint(Theme.accent)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).frame(width: 28).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copied = label
    }

    private func markAsPaid() {
        working = true
        Task {
            do {
                try await model.recordPayment(
                    groupID: group.id, from: settlement.from, to: settlement.to,
                    amountMinor: settlement.amountMinor, toName: to
                )
                dismiss()
            } catch {
                message = AppModel.message(for: error)
                working = false
            }
        }
    }
}

/// The ways one participant can be paid. Every field is optional and nothing is checked against a service.
private struct PaymentDetailsForm: View {
    let name: String
    @Binding var handles: PaymentHandles
    let save: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CardSection("Bizum") {
                    field("Phone number", text: binding(\.bizumPhone), id: "bizumPhone", keyboard: .phonePad)
                }
                CardSection("PayPal") {
                    field("PayPal.me name", text: binding(\.payPalMe), id: "payPalMe", keyboard: .URL)
                }
                CardSection("Revolut") {
                    field("Revolut.me tag", text: binding(\.revolutTag), id: "revolutTag", keyboard: .URL)
                }
                CardSection("Bank transfer") {
                    field("IBAN", text: binding(\.iban), id: "iban", keyboard: .asciiCapable)
                }
                if let iban = handles.iban, !iban.isEmpty, PaymentLinks.normalizedIBAN(iban) == nil {
                    Text("This IBAN does not look right. Check it before copying it.")
                        .font(.footnote).foregroundStyle(Theme.warning).padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .brandScreen()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: handles) { save() }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, id: String, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(16)
            .accessibilityIdentifier(id)
    }

    private func binding(_ keyPath: WritableKeyPath<PaymentHandles, String?>) -> Binding<String> {
        Binding(
            get: { handles[keyPath: keyPath] ?? "" },
            set: { handles[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
