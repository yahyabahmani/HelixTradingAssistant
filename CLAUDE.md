# CLAUDE.md

**Read [AGENTS.md](AGENTS.md) — it is the single working brief for this
repository** (architecture, build & run, key patterns, conventions &
gotchas, iPad target, open work, version history, and the
mandatory session-logging workflow). Everything that used to live in
README.md, CHANGELOG.md, the release notes, CTS_IMPROVEMENT_PLAN.md, and
ipadapp/REDESIGN.md was consolidated there.

Quick reminders (details in AGENTS.md):

- Build from the **repo root**: `xcodegen generate` then `xcodebuild
  -project HelixTradingApp.xcodeproj -scheme HelixTradingApp
  -configuration Debug -destination 'platform=macOS' build` (or `./run.sh`).
  `project.yml` is the source of truth; the `.xcodeproj` is gitignored.
- macOS 13 / iOS 16 baseline — no `@Observable`, no `initial:` `onChange`.
- Always build after substantive changes, before presenting the diff.
- Read `sessions/*.md` (last 7 days) before starting; write a session log
  to `sessions/` before finishing.
