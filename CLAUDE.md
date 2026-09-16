# Caliper

## Where the planning documents are

The PRD, the development plan and the lessons file are **not in this
repository**. They live in the private `caliper-notes` repository, cloned
alongside this one at `../caliper-notes`:

| document | path |
|---|---|
| PRD | `../caliper-notes/PRD.md` |
| development plan and review log | `../caliper-notes/todo.md` |
| lessons | `../caliper-notes/lessons.md` |

Read them from there, and write plans, review-log entries and lessons there
too. Do not recreate `tasks/` or `docs/PRD.md` here; both are in `.gitignore`
for that reason.

They were moved out because most of the plan is about work that has not been
done yet, and this repository is public. `docs/` still holds the screenshots
the README uses, and those stay.

## The development build

Debug builds a *different app*: `Caliper Dev.app`,
`com.olegklimakov.caliper.dev`, its own icon, its own settings domain, its own
history store under `Application Support/Caliper Dev`, and no update feed.
Release is untouched — `Caliper.app`, `com.olegklimakov.caliper`, the real
appcast.

**Install it only with `Scripts/install_dev.sh`**, which deletes the copy in
`/Applications` before putting the new one there, and builds into `build/dd`.
Never copy a bundle over one that is already there, and never point a dev build
at another derived-data path: both leave a second app on the Mac that Spotlight,
the Dock and the login items list show beside the first, with nothing to tell
them apart.

`assets/icon/AppIcon.icns` and `AppIcon-Dev.icns` are both generated from the
same render by `Scripts/make_icons.sh` and committed; a build needs neither
step.

## What stays public

Source, `README.md`, `NOTICE`, `LICENSE`, `release-notes/`, the screenshots in
`docs/`, and the releases that serve the update channel.

## Third-party code

`NOTICE` names every component the app is built on. Anything carried across
from another project keeps its copyright header above ours and gains an entry
there — that is what the MIT licence asks in return, and it is checked: a build
whose bundle does not carry `NOTICE` fails `Scripts/smoke_test.sh`.
