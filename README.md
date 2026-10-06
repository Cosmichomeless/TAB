# TAB

## Project Overview

TAB is an offline-first expense splitting application designed for groups such as:

- Trips.
- Flatmates.
- Events.
- Groups of friends.

The application allows users to create shared expenses even when they have no internet connection.

When connectivity returns, changes should synchronize automatically between devices.

The main objective of the project is to explore offline-first architecture and distributed data synchronization.

---

# Main Goal

Users should be able to create a group such as:

LISBON TRIP

Members:

- Ana
- Bruno
- Marta
- David

Expenses:

Dinner
186.40 €

Taxi
22.80 €

Airbnb
640.00 €

The application calculates who owes money to whom.

---

# Key Technical Idea

The local database should be the primary application data source.

NOT:

UI
    ↓
API
    ↓
DATABASE

Instead:

UI
    ↓
LOCAL DATABASE
    ↓
SYNC ENGINE
    ↓
REMOTE DATABASE

This allows the application to work completely offline.

---

# Technology Stack

## Mobile

- React Native
- Expo
- TypeScript

## Local Database

- SQLite

## ORM

- Drizzle ORM

## Synchronization

- PowerSync

## Backend

- Supabase

## State

Zustand may be used for temporary UI state.

Persistent domain data should live primarily in the database.

## Styling

- NativeWind

---

# Technical Objectives

This project should demonstrate:

- Offline-first architecture.
- Local databases.
- SQL.
- Synchronization.
- Optimistic UI.
- Conflict handling.
- Authentication.
- Realtime data.
- Data modeling.
- Distributed state.
- Network failure handling.

---

# Core Principle

The app must remain useful without internet.

Example:

User enters airplane mode.

    ↓

Creates expense.

    ↓

Expense saved locally.

    ↓

UI immediately updates.

    ↓

Internet returns.

    ↓

Synchronization begins.

    ↓

Other group members receive change.

---

# Main Entities

## User

User {
    id
    name
    email
}

## Group

Group {
    id
    name
    createdBy
    createdAt
}

## GroupMember

GroupMember {
    id
    groupId
    userId
}

## Expense

Expense {
    id
    groupId
    paidBy
    title
    amount
    currency
    createdAt
    updatedAt
}

## ExpenseSplit

ExpenseSplit {
    id
    expenseId
    userId
    amount
}

---

# Example

Expense:

Dinner
€100

Paid by:
David

Split between:

David
Ana
Bruno
Marta

Each owes:

€25

Balances become:

Ana owes David €25
Bruno owes David €25
Marta owes David €25

---

# Balance Calculation

Balances should be derived from expenses rather than stored as authoritative values whenever possible.

Example:

Expenses
    ↓
Splits
    ↓
Net balances
    ↓
Settlement suggestions

---

# Offline-First Architecture

Suggested flow:

React Native UI

    ↓

SQLite

    ↓

PowerSync

    ↓

Supabase / PostgreSQL

    ↓

PowerSync

    ↓

Other devices

---

# Synchronization States

Records may have states such as:

- Synced.
- Pending.
- Failed.
- Conflict.

The UI should communicate when changes are waiting to synchronize.

Example:

Offline — 3 changes waiting to sync

---

# Conflict Scenario

Example:

David is offline.

He changes:

Dinner → €100

At the same time Ana changes:

Dinner → €120

Both devices reconnect.

The system must determine:

- Which change wins?
- Whether both changes can be merged.
- Whether the user must resolve the conflict.

Conflict-resolution strategy should be explicitly designed and documented.

---

# Possible Conflict Strategy

For MVP:

Last-write-wins may be acceptable for simple fields.

However, the architecture should document its limitations.

More advanced strategies can later be explored.

---

# Optimistic UI

When the user creates an expense:

Press Add Expense

    ↓

Save immediately locally

    ↓

UI updates instantly

    ↓

Background synchronization happens later

The user should not wait for a server response.

---

# Authentication

Supabase Auth may be used.

Authentication should allow users to:

- Create an account.
- Log in.
- Join groups.

Authentication should not block local architecture decisions.

---

# Main Screens

## Groups

Example:

Lisbon Trip
Flat Expenses
Weekend Madrid

## Group Details

Display:

- Members.
- Balance.
- Expenses.

## Add Expense

Fields:

- Description.
- Amount.
- Paid by.
- Participants.
- Split method.

## Expense Details

Display:

- Total.
- Payer.
- Split.
- Sync status.

---

# Split Methods

Initial MVP:

Equal split.

Example:

€120 / 4 people = €30 each.

Future possibilities:

- Exact amounts.
- Percentages.
- Shares.

Do not implement them initially unless required.

---

# Architecture

Suggested structure:

src/

features/
    groups/
    expenses/
    balances/
    authentication/

database/
    schema/
    migrations/
    repositories/

sync/
    powersync/

services/
    balances/
    settlement/

store/

components/

types/

---

# MVP

The MVP should contain:

- Authentication.
- Create group.
- Add members.
- Add expense.
- Equal split.
- Calculate balances.
- Local SQLite storage.
- Offline usage.
- Synchronization.
- Sync status.
- Group history.

---

# Features Outside Initial MVP

Do NOT implement initially:

- Payments.
- Bank integrations.
- Multi-currency conversion.
- Receipt OCR.
- Chat.
- Social network.
- Complex notifications.
- AI features.
- Advanced analytics.

The objective is offline synchronization, not feature quantity.

---

# Important Engineering Challenges

## 1. Source of Truth

The local database should drive the UI.

---

## 2. Synchronization

Changes should synchronize automatically when connectivity returns.

---

## 3. Conflicts

Concurrent modifications must have a predictable behavior.

---

## 4. Data Consistency

Expenses, splits and balances must remain mathematically consistent.

---

## 5. Optimistic UX

Offline operations should feel identical to online operations.

---

# Development Phases

## Phase 1 — Product Definition

Define:

- Groups.
- Expenses.
- Splits.
- Balances.
- User flows.

## Phase 2 — Data Model

Design:

- PostgreSQL schema.
- SQLite schema.
- Relationships.

## Phase 3 — Local Application

Build the app using only SQLite first.

Implement:

- Groups.
- Expenses.
- Splits.
- Balances.

## Phase 4 — Authentication

Integrate Supabase Auth.

## Phase 5 — Synchronization

Integrate PowerSync.

Test:

- Offline creation.
- Offline update.
- Reconnection.
- Multi-device changes.

## Phase 6 — Conflict Handling

Define and implement conflict rules.

## Phase 7 — Reliability

Test:

- Connection loss.
- App restart.
- Sync failures.
- Duplicate operations.

## Phase 8 — Documentation

Document:

- Offline-first architecture.
- Sync architecture.
- Database model.
- Conflict strategy.
- Technical trade-offs.

---

# Portfolio Value

TAB should demonstrate knowledge of:

- SQL.
- Local databases.
- Distributed systems concepts.
- Offline-first architecture.
- Synchronization.
- Conflict resolution.
- Optimistic UI.
- Data consistency.
- React Native architecture.

The main portfolio story should not be:

"I built a Splitwise clone."

It should be:

"I built an offline-first mobile application with local persistence, optimistic updates, synchronization and conflict handling."
