# Branches and releases

`develop` is the default branch. `main` only holds released code and changes
only through a pull request from `develop`.

```
feat/… fix/… bug/… chore/…  ──PR──▶  develop  ──PR──▶  main  ──▶  release/<version> + tag v<version>
```

1. **Start from `develop`**: `git switch develop && git pull && git switch -c feat/hover-title`.
   Prefixes: `feat/`, `fix/`, `bug/`, `chore/`, and also `docs/`, `refactor/`, `perf/`, `test/`, `ci/`.
2. **Open a pull request into `develop`.** It needs the *Branch rules* and *Core tests*
   checks to pass. Squash or merge it.
3. **Release**: bump `CFBundleShortVersionString` (and `CFBundleVersion` by one) in
   `project.yml` with a `chore/` PR into `develop`, then open a PR from `develop` into
   `main` and merge it with a merge commit. The check refuses a version that is
   already released.
4. **The Release workflow** then creates `release/<version>`, the tag `v<version>` and a
   GitHub release. Its notes list the merged PRs under Features, Fixes and Chores,
   from the label each PR gets from its branch name.
5. **Attach the signed DMG** from your Mac:
   ```sh
   git fetch && git switch release/<version>
   scripts/release.sh --upload
   ```

Nobody can push directly to `main` or `develop`, force-push them or delete them.
