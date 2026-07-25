@__OWNER__ — agman passed Homebrew's 30-day repository-age requirement on **__ELIGIBLE__**. The repository is now __AGE__ days old.

__VERDICT__

## Where the numbers stand

| Metric | Now | Needed if you submit | Needed if someone else submits |
|---|---|---|---|
| Stars | __STARS__ | 225 | 75 |
| Forks | __FORKS__ | 90 | 30 |
| Watchers | __WATCHERS__ | 90 | 30 |

Meeting **any one** row is enough. Homebrew's [Package Acceptance Policy](https://github.com/Homebrew/brew/blob/master/docs/Package-Acceptance-Policy.md#notability) holds a self-submission by the repository owner to the higher bar.

## The rest of the checklist

- [ ] **Public presence and maintenance** — a homepage that explains the project (the [landing page](https://memandip.github.io/agman) covers this) plus evidence of active upstream maintenance.
- [ ] **Stable versioned release** — an immutable tag with a release archive verified by SHA-256. Already how agman ships.
- [ ] **Builds without downstream patches** — a single script install, so this holds.
- [ ] **The name is still free** — re-check that nothing called `agman` has landed in homebrew-core meanwhile.
- [ ] **Re-read the policy** before submitting; it carries a `last_review_date` and is revised periodically.

Worth remembering: [maintainer discretion](https://github.com/Homebrew/brew/blob/master/docs/Package-Acceptance-Policy.md#maintainer-discretion) applies. "Meeting the documented criteria does not guarantee acceptance", and "New submissions may be held to a higher standard than existing packages because accepting a package creates an ongoing maintenance commitment."

## If you go ahead

Open a pull request against [homebrew-core](https://github.com/Homebrew/homebrew-core) adding the formula, and keep [memandip/homebrew-agman](https://github.com/memandip/homebrew-agman) in place for anyone already tapped.

Nothing breaks if you never do this. `brew install memandip/agman/agman` keeps working, and `brew install agman` works once the tap is trusted.

<sub>Opened automatically by `.github/workflows/homebrew-core-reminder.yml`. Delete that workflow once it is no longer useful.</sub>
