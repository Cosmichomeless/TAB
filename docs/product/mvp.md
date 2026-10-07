# TAB — MVP and User Flows

This document defines the scope of the first version of TAB and the user flows it must support. It is derived from the MVP and roadmap sections of the README.

## Goals

- Let a group of people record shared expenses and know who owes whom.
- Work fully offline: no core flow may depend on network availability.
- Reflect every local action in the UI immediately (optimistic updates).
- Synchronize with the backend after reconnection and expose the synchronization status.

## Actors

| Actor | Description |
|-------|-------------|
| User | A registered person with an account (`id`, `name`, `email`). |
| Group creator | The user who created a group. |
| Member | A user who belongs to a group and can take part in its expenses. |

## MVP Scope

### In scope

1. Registration and login
2. Group creation
3. Adding participants to a group
4. Expense entry: title, amount, currency, payer and participants
5. Equal split among the selected participants
6. Net balance calculation per member
7. Settlement suggestions
8. Group expense history
9. Local persistence
10. Full basic functionality while offline
11. Optimistic updates
12. Synchronization after reconnection
13. Synchronization status per change

### Out of scope

Complex split strategies (by percentage, shares or exact amounts), payments, bank integrations, receipt OCR, automatic currency conversion, chat, social features, AI features and advanced analytics. The only split strategy in the MVP is equal splitting.

## User Flows

### 1. Registration and login

1. The user opens the app for the first time and chooses to register.
2. The user enters name, email and password.
3. The account is created and the user lands on the group list.
4. On later launches, the user logs in with email and password, or resumes the stored session.

Notes:

- Authentication needs connectivity the first time. After a successful login, the session is kept locally so the app remains usable offline.

### 2. Group creation

1. From the group list, the user taps "New group".
2. The user enters a group name.
3. The group is stored locally, appears in the list immediately and is marked as pending synchronization.
4. The creator is added automatically as the first member.

### 3. Adding participants

1. Inside a group, the user opens the member list and taps "Add participant".
2. The user adds a participant by name or email.
3. The membership is stored locally, shown immediately and marked as pending synchronization.

### 4. Expense entry

1. Inside a group, the user taps "Add expense".
2. The user enters a title and an amount, and the currency defaults to the group currency.
3. The user selects the payer (defaults to the current user).
4. The user selects the participants who share the expense (defaults to all members).
5. The user confirms. The expense is stored locally, shown immediately in the history and marked as pending synchronization.

Validation:

- The title is required and the amount must be greater than zero.
- At least one participant is required.
- The payer must be a group member.

### 5. Equal split

1. When an expense is confirmed, its amount is divided equally among the selected participants.
2. Amounts are handled in minor units (cents) to avoid floating point errors.
3. When the amount does not divide evenly, the remainder cents are assigned deterministically so that the splits always add up to the total.
4. One `ExpenseSplit` per participant is stored.

### 6. Balances

1. The group screen shows each member's net balance, derived from expenses and splits.
2. A positive balance means the member is owed money; a negative balance means the member owes money.
3. The app suggests a minimal set of transfers that settles all debts.
4. Balances are always derived from source data and never stored as an independent source of truth.

### 7. Expense history

1. The group screen lists expenses from newest to oldest.
2. Each entry shows title, amount, payer and synchronization status.

### 8. Offline use and synchronization

1. With no connectivity, flows 2 to 7 behave exactly as they do online.
2. Each local change carries a status: `Synced`, `Pending`, `Failed` or `Conflict`.
3. When connectivity returns, pending changes synchronize in the background without user action.
4. The user can see which changes are still pending or have failed.

## Open Questions

- Group currency: single currency per group, or per expense with no conversion?
- How participants without an account are represented before they register.
- Whether expense editing and deletion belong in the MVP or in the conflict handling phase.

These questions are tracked in the related architecture and data model issues.
