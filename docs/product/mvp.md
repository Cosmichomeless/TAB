# TAB — product scope and user flows

This document defines what TAB 1.1 (the first App Store release) does and what it deliberately does not. It supersedes the original MVP, which assumed accounts and synchronization; that design is kept in the `TAB-Sync` build (see [local-only](../architecture/local-only.md)).

## Positioning

**Private group expenses, on your iPhone.** Splitwise, Tricount, Settle Up and Splid own the "shared expenses with accounts and a cloud" space. TAB takes the opposite and defensible angle:

- **No account, no server.** The first screen asks one question, your name. Groups, expenses and balances live in a SQLite database on the device.
- **No network.** The app contains no network code and asks for no permission. The claim is checkable: the `TAB` target links only `TABCore`, and the App Store privacy label is "Data Not Collected".
- **Exact and fair.** Splits by equal share, shares, percentage or exact amount, in integer minor units, always adding up to the total.
- **Easy to hand over.** A group travels as a file, a QR code or a link, and a who-owes-whom summary pastes into any chat. Settling up opens PayPal or Revolut, or copies a Bizum number or IBAN, without TAB ever handling money.

Target users: friends on a trip, flatmates, and anyone who splits costs with a small group and does not want to create an account to do it. The first markets are Spanish-speaking, with French, Italian, Portuguese and German at launch.

### Beta goals (issue #37)

- First expense in under 60 seconds from install, without entering personal data beyond a name.
- 50 groups created with 3 or more participants during the TestFlight beta; use them to prioritise 1.2 (candidates: multi-currency, receipt photos, PDF/CSV export).

## Actors

| Actor | Description |
|-------|-------------|
| You | The person who owns the install. Entered once at first launch. |
| Participant | Anyone added to a group by name, with or without an email. They do not need the app. |

## Scope of 1.1

### In scope

1. First-launch profile (name only)
2. Groups with a currency (EUR, USD, GBP, JPY)
3. Participants
4. Expenses: title, amount, payer, participants
5. Four split methods: equal, shares, percentages, exact amounts
6. Editing and deleting expenses
7. Net balance per person and suggested settlements
8. Settling up: record a payment, with PayPal, Revolut, Bizum and IBAN shortcuts
9. Share a group (file, QR code, link) and a text summary; import with update or copy
10. Backup, restore and delete all data
11. Full offline operation (there is no online)
12. Localisation: English, Spanish, French, Italian, Portuguese, German

### Out of scope

Accounts, synchronization, a backend, payments or bank connections, receipt photos and OCR, currency conversion, notifications, chat, social features, analytics and iPad or Mac layouts. Multi-currency expenses (#42), receipt photos (#43) and PDF/CSV export (#44) are candidates for a later version.

## User flows

### 1. First launch

1. The user opens the app and sees one question: "What should we call you?"
2. The user enters a name and continues. No other data is requested and no permission is asked.
3. The user lands on an empty group list.

### 2. Group creation

1. From the group list, the user taps "New group".
2. The user enters a name and picks a currency. Every expense in the group uses that currency.
3. The group appears in the list at once; the user is its first participant.

### 3. Participants

1. Inside a group, the user taps "Add participant".
2. The user enters a name, and optionally an email. An invalid email is rejected.

### 4. Expenses and splits

1. Inside a group, the user taps "Add expense" and enters a title and an amount (`12.5`, `12,50`, `1.234,50` and `1,234.50` all work; a lone separator before three digits follows the device language).
2. The user picks the payer and the split method:
   - **Equal:** shared among the selected participants; leftover cents are assigned deterministically.
   - **Shares:** each person pays in proportion to their parts; an empty field leaves someone out.
   - **Percent:** percentages must add up to 100.
   - **Exact:** amounts must add up to the expense total. The form shows what is left to assign.
3. The expense is saved locally and listed at once.

Validation: the title is required, the amount must be greater than zero, at least one participant is required, and the split must be consistent with the amount.

### 5. Editing and deleting

1. Tapping an expense opens it for editing. If the amount and participants stay the same, an existing custom split is kept; otherwise the form warns that the split will be recalculated.
2. Swipe or long-press to delete, with confirmation. Balances are recalculated.

### 6. Balances and settling up

1. The group screen shows the total spent, where the user stands, each person's net balance and a minimal set of suggested payments. A positive balance means the person is owed money.
2. Balances are always derived from the expenses and never stored.
3. Tapping a suggested payment opens "Settle up": the user can store how someone prefers to be paid (on this iPhone only), open PayPal or Revolut or copy the Bizum number or IBAN, and "Mark as paid" to record the payment as an expense so the balances update.

### 7. Sharing

1. "Share group" creates a snapshot: a QR code, a `.tabgroup` file and a `tab://` link, plus a text summary of who owes whom.
2. Opening one of them in TAB shows what it contains and asks how to import it: update the group you already have, or add a copy; and which participant is "you".
3. Nothing is uploaded. A shared group is a copy; later changes are not shared automatically.

### 8. Backup, restore and delete

1. Settings exports every group to a `.tabbackup` file and restores from one (replacing what is on the iPhone, after confirmation).
2. "Delete all data" removes every group, expense and the profile after two confirmations.
3. Settings also links to the privacy policy and the support page.

## Decisions taken

- One currency per group, with no conversion.
- People without the app are first-class participants.
- Expense editing and deletion are in scope.
