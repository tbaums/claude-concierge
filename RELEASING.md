# Releasing

This project uses [Semantic Versioning](https://semver.org). Releases are cut
manually with the GitHub CLI — there is **no CI**; the only gate is the local
test runner below.

## 1. Run the local tests

Always green before tagging. No network, no GitHub Actions — it runs the real
scripts in a throwaway sandbox (temp `HOME` + temp tmux socket) so it never
touches your actual install:

```sh
bash test/run.sh
```

It checks:

- every shipped file exists;
- shell syntax (`zsh -n`, `sh -n`, `bash -n`) and Python compile;
- the tmux config loads and applies (`mouse on`, top status bar, 50k scrollback,
  `copy-command` path expansion, all mouse/copy/scroll bindings present);
- `logsink.sh` strips ANSI to readable text;
- `clip.sh` never copies an empty selection but does copy a real one;
- the iTerm2 profile generates valid JSON with the expected keys.

Exit code is non-zero on any failure, so you can also chain it:
`bash test/run.sh && echo ok-to-release`.

## 2. Update the changelog

Add a new section to [`CHANGELOG.md`](CHANGELOG.md) under the new version with
the date and a summary of changes. Update the comparison/link at the bottom.

## 3. Tag and release

```sh
VERSION=0.1.0

git add -A
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin main --tags

# Create the GitHub release with notes pulled from the changelog section.
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --notes-from-tag
```

If `--notes-from-tag` isn't what you want, pass `--notes "…"` or
`--notes-file path` instead.

## 4. Verify

```sh
gh release view "v$VERSION" --web
```

## Versioning guide

- **PATCH** (`0.1.x`) — bug fixes, doc tweaks, theme color nudges.
- **MINOR** (`0.x.0`) — new flags/features, new bindings, backward-compatible
  config additions.
- **MAJOR** (`x.0.0`) — changes that break an existing install (renamed paths,
  removed flags, incompatible config layout).
