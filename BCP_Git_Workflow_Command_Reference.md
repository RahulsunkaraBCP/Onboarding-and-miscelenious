# Git Command Reference for BCP Dev Workflow

> Practical Git cheat sheet for day-to-day work in `brooke-rasa-poc`.

## Typical flow

```text
origin/dev
   ↓
local dev
   ↓
feature/ticket branch
   ↓
validate changes
   ↓
commit
   ↓
push branch
   ↓
PR into dev
   ↓
merge
   ↓
refresh local dev
```

---

## 1. Check where you are

```bash
pwd
git status
git branch --show-current
git remote -v
```

Quick version:

```bash
echo "Branch: $(git branch --show-current)"
git status --short
```

Confirm the repo:

```bash
git remote get-url origin
```

---

## 2. Fetch latest GitHub state

```bash
git fetch origin
```

This updates your knowledge of remote branches and commits without changing your working files.

See branches:

```bash
git branch -a
```

Find DEV branches:

```bash
git branch -a | grep dev
```

Latest remote DEV commit:

```bash
git log origin/dev -1 --oneline
```

---

## 3. Switch to local DEV

If local `dev` exists:

```bash
git switch dev
```

If it does not exist:

```bash
git switch -c dev --track origin/dev
```

One command for either case:

```bash
git switch dev 2>/dev/null || git switch -c dev --track origin/dev
```

Verify:

```bash
git branch --show-current
```

---

## 4. Update local DEV safely

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
```

Why `--ff-only`?

It prevents Git from creating an unexpected merge commit while updating local `dev`.

Verify:

```bash
git log -1 --oneline --decorate
```

---

## 5. Create a ticket branch from latest DEV

Example:

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-304
```

Verify:

```bash
git branch --show-current
git status
git log -3 --oneline --decorate
```

---

## 6. If the branch was created from the wrong base

If you accidentally created `SYST-304` from `main` and have no work to keep:

```bash
git switch dev
git pull --ff-only origin dev
git branch -D SYST-304
git switch -c SYST-304
```

---

## 7. Check changed files

```bash
git status --short
```

Typical meanings:

```text
M  modified
A  added
D  deleted
?? untracked/new
```

Full status:

```bash
git status
```

---

## 8. Review unstaged changes

All changes:

```bash
git diff
```

One file:

```bash
git diff -- path/to/file.yaml
```

Summary:

```bash
git diff --stat
```

Changed filenames:

```bash
git diff --name-only
```

Whitespace check:

```bash
git diff --check
```

Healthy result: no output.

---

## 9. Compare your branch with DEV

Fetch first:

```bash
git fetch origin
```

Commits on your branch that are not in DEV:

```bash
git log origin/dev..HEAD --oneline
```

PR-style file diff:

```bash
git diff origin/dev...HEAD
```

Summary:

```bash
git diff --stat origin/dev...HEAD
```

Changed files:

```bash
git diff --name-status origin/dev...HEAD
```

---

## 10. Stage files

One file:

```bash
git add path/to/file.yaml
```

Multiple specific files:

```bash
git add   path/to/file1.yaml   path/to/file2.yaml   path/to/file3.sh
```

Everything:

```bash
git add .
```

For infrastructure work, staging specific files is usually safer than `git add .`.

---

## 11. Review staged changes

```bash
git status --short
git diff --cached
git diff --cached --stat
git diff --cached --name-status
git diff --cached --check
```

Healthy `git diff --cached --check`: no output.

---

## 12. Confirm a sensitive file was not staged

Example:

```bash
git diff --cached --name-only | grep 'deploy-dev.yaml'   && echo "STOP: deploy-dev.yaml was staged"   || echo "PASS: deploy-dev.yaml untouched"
```

---

## 13. Unstage a file

```bash
git restore --staged path/to/file.yaml
```

Unstage everything:

```bash
git restore --staged .
```

This does not remove your working-file changes.

---

## 14. Discard an unstaged change

Be careful: this removes your local change.

```bash
git restore path/to/file.yaml
```

---

## 15. Commit

```bash
git commit -m "SYST-304 add KEDA-based Rasa autoscaling"
```

Verify:

```bash
git log -1 --oneline
git status
```

---

## 16. Push a new branch

First push:

```bash
git push -u origin SYST-304
```

After that:

```bash
git push
```

Check tracking:

```bash
git branch -vv
```

---

## 17. Open a PR

Typical PR:

```text
Base: dev
Compare: SYST-304
```

Before creating it:

```bash
git fetch origin
git diff --stat origin/dev...HEAD
git log origin/dev..HEAD --oneline
```

---

## 18. Update your feature branch when DEV has moved

```bash
git fetch origin
```

Merge latest DEV into your branch:

```bash
git switch SYST-304
git merge origin/dev
```

Or rebase:

```bash
git switch SYST-304
git rebase origin/dev
```

Use the method your team prefers.

---

## 19. Resolve merge conflicts

Check conflicted files:

```bash
git status
```

Fix conflict markers:

```text
<<<<<<<
=======
>>>>>>>
```

Then:

```bash
git add path/to/resolved-file
```

If merging:

```bash
git commit
```

If rebasing:

```bash
git rebase --continue
```

Abort merge:

```bash
git merge --abort
```

Abort rebase:

```bash
git rebase --abort
```

---

## 20. Cherry-pick one commit

Find the commit:

```bash
git log --all --oneline --decorate
```

Example commit:

```text
66749f4 SYST-304 separate KEDA platform ownership
```

Create a clean branch from DEV:

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-305
```

Cherry-pick:

```bash
git cherry-pick 66749f4
```

Verify:

```bash
git status
git log -3 --oneline
```

---

## 21. Cherry-pick multiple commits

Specific commits:

```bash
git cherry-pick abc1234 def5678 123abcd
```

A range:

```bash
git cherry-pick oldest_commit^..newest_commit
```

---

## 22. Resolve cherry-pick conflicts

```bash
git status
```

Fix files, then:

```bash
git add path/to/resolved-file
git cherry-pick --continue
```

Abort:

```bash
git cherry-pick --abort
```

Skip one commit:

```bash
git cherry-pick --skip
```

Use `--skip` only when you know that commit is not needed.

---

## 23. Undo the latest local commit but keep changes

Keep changes staged:

```bash
git reset --soft HEAD~1
```

Keep changes but unstage them:

```bash
git reset HEAD~1
```

Avoid `git reset --hard` unless you are certain you want to destroy local work.

---

## 24. Amend the latest commit

Add a forgotten file:

```bash
git add missing-file.yaml
git commit --amend --no-edit
```

Change commit message:

```bash
git commit --amend
```

If already pushed, use:

```bash
git push --force-with-lease
```

Prefer `--force-with-lease` over `--force`.

---

## 25. Stash temporary work

```bash
git stash
```

Include untracked files:

```bash
git stash -u
```

List:

```bash
git stash list
```

Restore and remove from stash:

```bash
git stash pop
```

Restore without deleting stash:

```bash
git stash apply
```

---

## 26. Switch branches when you have local changes

If Git blocks the switch:

```bash
git stash -u
git switch dev
```

Later:

```bash
git switch your-feature-branch
git stash pop
```

---

## 27. After a PR is merged into DEV

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
```

Verify:

```bash
git log -5 --oneline --decorate
```

Delete local feature branch:

```bash
git branch -d SYST-304
```

If Git refuses but you know it is safe:

```bash
git branch -D SYST-304
```

---

## 28. Delete a remote feature branch

```bash
git push origin --delete SYST-304
```

Clean stale remote references:

```bash
git fetch --prune origin
```

---

## 29. Start the next ticket

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-305
```

Verify:

```bash
git branch --show-current
git status
git log -3 --oneline --decorate
```

---

## 30. Create a fix branch after a merged change fails

Pattern used for the KEDA deployment fix:

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-304-keda-deploy-fix
```

After fixing:

```bash
git diff --check
git status --short
git add <specific files>
git diff --cached --check
git diff --cached --stat
git commit -m "SYST-304 separate KEDA platform ownership"
git push -u origin SYST-304-keda-deploy-fix
```

Then PR back into `dev`.

---

## 31. Find which branch contains a commit

Local:

```bash
git branch --contains <commit>
```

Remote:

```bash
git branch -r --contains <commit>
```

All:

```bash
git branch -a --contains <commit>
```

---

## 32. Find a commit by message

```bash
git log --all --oneline --grep='KEDA'
```

Example:

```bash
git log --all --oneline --grep='SYST-304'
```

---

## 33. View a specific commit

Summary:

```bash
git show --stat <commit>
```

Full diff:

```bash
git show <commit>
```

---

## 34. Compare two branches

```bash
git diff --stat dev..SYST-304
git diff dev..SYST-304
git log dev..SYST-304 --oneline
git log SYST-304..dev --oneline
```

For PR-style comparison:

```bash
git diff origin/dev...HEAD
```

---

## 35. Check whether your branch is behind DEV

```bash
git fetch origin
git rev-list --left-right --count origin/dev...HEAD
```

Example:

```text
2    3
```

Meaning:

```text
2 commits are on DEV but not your branch
3 commits are on your branch but not DEV
```

---

## 36. Show branch history visually

```bash
git log --graph --oneline --decorate --all --max-count=30
```

---

## 37. Validate Helm/YAML/shell changes before commit

Rasa scaling chart:

```bash
helm lint k8s/charts/rasa-scaling   -f k8s/dev/rasa-scaling-values.yaml
```

Render:

```bash
helm template rasa-scaling k8s/charts/rasa-scaling   -n rasa   -f k8s/dev/rasa-scaling-values.yaml
```

Validate shell:

```bash
bash -n k8s/scripts/deploy-rasa-scaling.sh
```

Validate GitHub Actions YAML:

```bash
ruby -e '
require "yaml"
YAML.parse_file(".github/workflows/rasa-scaling-validate.yaml")
puts "PASS: workflow YAML is valid"
'
```

Always finish with:

```bash
git diff --check
```

---

## 38. Full normal ticket workflow

Example `SYST-305`:

```bash
# Get latest DEV
git fetch origin
git switch dev
git pull --ff-only origin dev

# Create branch
git switch -c SYST-305

# Confirm starting point
git branch --show-current
git status
git log -3 --oneline --decorate

# Make changes...

# Review
git status --short
git diff
git diff --stat
git diff --check

# Validate app/infra changes
# helm lint ...
# bash -n ...
# terraform fmt -check ...
# terraform validate ...

# Stage intended files
git add   path/to/file1   path/to/file2

# Review staged content
git status --short
git diff --cached
git diff --cached --check
git diff --cached --stat

# Commit
git commit -m "SYST-305 describe the change"

# Verify
git status
git log -1 --oneline

# Push
git push -u origin SYST-305
```

Then open:

```text
Base: dev
Compare: SYST-305
```

---

## 39. Full fix-after-merge workflow

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-305-fix

# Make fix

git diff --check
git add <files>
git diff --cached --check
git commit -m "SYST-305 fix deployment issue"
git push -u origin SYST-305-fix
```

---

## 40. Full cherry-pick workflow

Suppose the desired commit is `abc1234`:

```bash
git fetch origin

git switch dev
git pull --ff-only origin dev

git switch -c SYST-306

git cherry-pick abc1234

git status
git log -3 --oneline

git diff origin/dev...HEAD
git diff --check

git push -u origin SYST-306
```

---

## 41. Commands to use carefully

These can destroy or rewrite work:

```bash
git reset --hard
git clean -fd
git push --force
git branch -D
git restore <file>
```

Safer alternatives often include:

```bash
git stash -u
git restore --staged
git push --force-with-lease
git branch -d
```

---

## 42. Daily cheat sheet

### Start new work

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-XXX
```

### Check work

```bash
git status --short
git diff
git diff --check
```

### Stage and review

```bash
git add <files>
git diff --cached --check
git diff --cached --stat
git diff --cached
```

### Commit and push

```bash
git commit -m "SYST-XXX description"
git push -u origin SYST-XXX
```

### After merge

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git branch -d SYST-XXX
```

### Cherry-pick

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c SYST-XXX
git cherry-pick <commit>
```

### Abort cherry-pick

```bash
git cherry-pick --abort
```

### See branch graph

```bash
git log --graph --oneline --decorate --all --max-count=30
```

---

## 43. Mental model

```text
git fetch
= update my knowledge of GitHub

git switch dev
= move my local working directory to DEV

git pull --ff-only
= safely move local DEV to the latest remote DEV

git switch -c SYST-XXX
= create my isolated work branch

git diff
= inspect unstaged changes

git add
= choose what goes into the next commit

git diff --cached
= inspect exactly what will be committed

git commit
= create a local snapshot

git push
= send my branch/commits to GitHub

PR
= request merge into DEV

git cherry-pick
= copy a specific commit onto my current branch
```

---

## 44. Rule of thumb

Before every new ticket:

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
git switch -c <ticket>
```

Before every commit:

```bash
git status --short
git diff --check
git diff --cached --check
```

Before every PR:

```bash
git fetch origin
git diff --stat origin/dev...HEAD
git log origin/dev..HEAD --oneline
```

After every merge:

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
```

This routine prevents most common Git mistakes.
