# MileLog — Xcode build checklist

Everything below is configuration that lives in the Xcode project or the
Supabase dashboard, not in source — so none of it can be set from this
repo, and none of it was verifiable by the review rounds. Work through it
once; after that, `⌘B` is the whole loop.

**This code has never been compiled.** It was written and reviewed entirely
in a Linux container with no Swift toolchain. Expect a first build to
surface real errors — that is the point of this step, and the list at the
bottom names the places I consider most likely to break.

---

## 1. Create the target

1. Xcode → **File → New → Project → iOS → App**.
   - Product name: `MileLog`
   - Interface: **SwiftUI**, Language: **Swift**
   - **Minimum deployment target: iOS 17.0** (required — see §5)
2. Delete the auto-generated `ContentView.swift` and `MileLogApp.swift`.
3. Drag in the `MileLog/` source folder (37 files, including `Views/`).
   Check **Copy items if needed** and **Create groups**.
4. Confirm all 37 files appear in *Target → Build Phases → Compile Sources*.
   A file silently missing from the target is the most common cause of a
   "cannot find X in scope" error that looks impossible.

## 2. Add the Supabase package

*File → Add Package Dependencies* → `https://github.com/supabase/supabase-swift`

Add the **Supabase** product to the MileLog target.

> Pin a version you're happy with. `supabase-swift` has changed its auth
> API across majors, and §5 lists the calls most sensitive to that.

## 3. Capabilities and Info.plist

**Signing & Capabilities → + Capability → Background Modes**, tick:
- ☑ **Location updates** — required. Both `TripDetector` and (since the
  round-4 UX fix) `LocationManager` set `allowsBackgroundLocationUpdates`,
  which **traps at runtime** if this is not enabled.

**Info tab → Custom iOS Target Properties**, add:

| Key | Value |
|---|---|
| `SUPABASE_URL` | `https://xxxx.supabase.co` |
| `SUPABASE_ANON_KEY` | your publishable/anon key |
| `Privacy - Location When In Use Usage Description` | *MileLog measures the distance of your trips.* |
| `Privacy - Location Always and When In Use Usage Description` | *MileLog records trips in the background so you don't have to.* |
| `Privacy - Camera Usage Description` | *Take a photo of a receipt to attach it to a trip.* |
| `Privacy - Photo Library Usage Description` | *Attach an existing receipt photo to a trip.* |
| `Privacy - Motion Usage Description` | *Confirms you're actually driving, so trips aren't started by walking.* |

> Never commit real `SUPABASE_*` values.

**Info tab → URL Types → +**
- URL Schemes: `milelog`

Without it, "Forgot password?" sends a mail whose link cannot re-enter the
app — the exact dead end round 6 fixed in source but which only works with
this registered.

## 4. Supabase dashboard

1. Run `supabase/schema.sql`, then every `supabase/migration-0NN-*.sql`
   **in numeric order** (002 → 016).
2. *Authentication → URL Configuration → Redirect URLs*: add
   `milelog://auth/reset`.
3. Storage: create a **`receipts`** bucket (private).

## 5. Where I'd expect the first errors

Ranked by how likely they are to bite, and why I couldn't rule them out:

1. **Supabase auth API signatures.** These were written against the
   documented API but never compiled against your resolved package version:
   - `client.auth.session(from: url)` — recovery-link exchange
   - `client.auth.update(user: UserAttributes(password:))`
   - `client.auth.resetPasswordForEmail(_:redirectTo:)`
   - `client.storage.from("receipts").remove(paths:)`
   If any fail, they're all confined to `SupabaseService.swift`.
2. **Swift 6 strict concurrency.** The project leans on `@MainActor`
   classes with `nonisolated` CoreLocation delegate methods that hop back
   via `Task { @MainActor in }`. If you've set *Strict Concurrency
   Checking* to **Complete**, expect diagnostics around `TripDetector`,
   `LocationManager`, and `NotificationManager`. Setting it to **Minimal**
   for the first successful build is a reasonable way to separate real
   errors from concurrency noise.
3. **Deployment target.** Must be **17.0**. Five two-parameter
   `onChange(of:)` call sites fail to build on 16.x.
4. **Missing files in the target** — see §1.4.

## 6. What to send back

The first ~20 compiler errors verbatim (with file and line) is far more
useful than a summary. Warnings can wait; errors first, in file order.
Once it builds, the highest-value runtime checks are:

- Sign in on a fresh install of an **existing** account → confirm your
  reimbursement rates and company header survive (rounds 7-9 fought over
  exactly this, and it is the one bug I would least trust to have stayed
  fixed).
- Start a manual trip, lock the phone, drive, unlock → distance should
  still be accumulating (round 4).
- Toggle auto-detect on with no vehicles added → should get a clear
  prompt, not silence (rounds 4-5).
