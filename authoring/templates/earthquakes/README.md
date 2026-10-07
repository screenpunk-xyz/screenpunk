# Earthquakes authoring template

Every user-entered preference is durable by default. This template uses
useScreenPreferences from the maintained React adapter, stable versioned keys
and a JSON schemaVersion. Retain dashboardId across updates. Controls remain
disabled until active runtime flags permit a successful restore; defaults are
never written on startup. Saves occur only on user edits/explicit Save, with
awaited success and visible failures. Unknown saved schemas remain untouched.

The updated adapter ships with the next reviewed kit; published kit 1.0.0 remains
immutable. See [the bundled persistence guide](../../PERSISTENCE.md). Check saved
values after app relaunch and an approved appearance-only screen revision.
Device-local state is not agent access/sync; Disconnect, device reset and app
removal can erase it.
