# Physical iPhone validation (issue #39)

TAB has only been exercised on simulators. Before the TestFlight build goes to testers, run this list on a real iPhone with a build of the `TAB` scheme (Release configuration, so what you test is what ships) and write the results below. Anything that fails blocks the release.

## Setup

- iPhone running iOS 17 or later, ideally also one older/smaller device.
- Install the `TAB` scheme. Keep a copy of the first backup you export.
- Use a real group (a trip or a flat) for a week, entering expenses as they happen.

## Checklist

### Persistence and recovery

- [ ] Add, edit and delete expenses, then force-quit the app (app switcher) mid-edit. Reopen: no data is lost and no half-saved expense appears.
- [ ] Force-quit right after saving an expense. The expense is there on reopen.
- [ ] Reboot the iPhone. Groups, expenses, balances and the profile are intact.
- [ ] Export a backup, "Delete all data", restore the backup. Everything returns, including who "you" are.
- [ ] Share a group as a file, a QR code and a link to a second device (or a second install) and import it, both as an update and as a copy.

### Performance

- [ ] Import or generate a group with 500+ expenses and 20+ participants. Opening the group, scrolling, adding an expense and editing one stay responsive (no visible hitch).
- [ ] Balances and suggested payments are correct on that group (spot-check against a spreadsheet).
- [ ] Cold start time on the device with that data is acceptable.

### Accessibility and appearance

- [ ] Dynamic Type from the smallest size up to the largest accessibility size: nothing is cut off on the group list, group detail, new expense, settle up and settings screens.
- [ ] VoiceOver can create a group, add a participant, add an expense, read the balances and settle up.
- [ ] Light and dark mode on every screen.
- [ ] Switch the device language to Spanish, French, Italian, Portuguese and German: no truncated buttons, no English left over, and amounts and dates use the device locale.

### Privacy

- [ ] With a proxy or the App Privacy Report (Settings → Privacy & Security → App Privacy Report) after a week of use: TAB made no network connections.
- [ ] No permission prompt appeared at any point.

## Results

| Date | Device and iOS | Build | Tester | Outcome |
| --- | --- | --- | --- | --- |
| | | | | |

Notes and defects found:

-
