# rclone + Backblaze B2 setup

One script that connects [rclone](https://rclone.org) to [Backblaze B2](https://www.backblaze.com/cloud-storage) and proves the connection actually works. Runs on **macOS, Linux and Windows**.

Setting up rclone for B2 is normally a walk through `rclone config`'s interactive menu — about twenty keystrokes and a couple of questions whose right answer is not obvious. This does the same thing in one command, then does the part `rclone config` never does: checks that the credentials can really read *and write* the bucket, and tells you plainly if they can't.

```
==> verifying
    ok    authenticated, and the key can list buckets (3 visible)
    ok    bucket 'photos-backup' is reachable
    ok    wrote a probe object
    ok    read it back
    ok    deleted it, leaving the bucket exactly as it was
```

If anything fails, the script removes the remote it just created instead of leaving a broken one in your config.

---

## Quick start

**1. Get a B2 application key** at [secure.backblaze.com/app_keys.htm](https://secure.backblaze.com/app_keys.htm) → *Add a New Application Key*. Scope it to one bucket. You get a **keyID** and an **applicationKey**; the applicationKey is shown exactly once.

**2. Run the script.**

macOS / Linux:

```bash
git clone https://github.com/adamsiwiec1/rclone-backblaze-b2-setup.git
cd rclone-backblaze-b2-setup
chmod +x connect.sh
./connect.sh --bucket YOUR-BUCKET-NAME
```

Windows (PowerShell):

```powershell
git clone https://github.com/adamsiwiec1/rclone-backblaze-b2-setup.git
cd rclone-backblaze-b2-setup
.\connect.ps1 -Bucket YOUR-BUCKET-NAME
```

If Windows blocks the script, it is unsigned — allow it for this session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

It will prompt for the keyID and applicationKey, install rclone if you don't have it (with your say-so), and verify everything. Don't have a bucket yet? Add `--create-bucket` / `-CreateBucket`.

---

## What a real run looks like

Verbatim from `./connect.sh --remote b2 --bucket rclone-b2-quickstart-demo --create-bucket`:

```
rclone + Backblaze B2 setup (connect.sh 1.0.0)

==> checking for rclone
    ok    rclone v1.75.0 found at /usr/local/bin/rclone
    config: /Users/you/.config/rclone/rclone.conf

==> credentials

==> writing remote 'b2'
    ok    remote 'b2' written to /Users/you/.config/rclone/rclone.conf

==> verifying
    ok    authenticated, and the key can list buckets (3 visible)
    ok    bucket 'rclone-b2-quickstart-demo' created
    ok    wrote a probe object
    ok    read it back
    ok    deleted it, leaving the bucket exactly as it was

Connected. Remote 'b2' is configured and working.

  Try it:
    rclone lsd b2:
    rclone ls b2:rclone-b2-quickstart-demo
    rclone copy ~/Documents b2:rclone-b2-quickstart-demo/Documents
    rclone sync ~/Documents b2:rclone-b2-quickstart-demo/Documents --dry-run

  Always --dry-run a sync first. sync makes the destination match the
  source, which means it deletes remote files that are gone locally.

  One thing worth doing now, once per bucket:
    rclone backend lifecycle b2:rclone-b2-quickstart-demo -o daysFromHidingToDeleting=30

    On B2, deleting a file only hides it -- the bytes stay billable forever
    unless a lifecycle rule removes them. That command gives you a 30-day
    undelete window, after which you stop paying. Needs rclone 1.65+.
```

And when the key is wrong:

```
==> verifying

      CRITICAL: Failed to create file system for "b2:": failed to authorize
      account: failed to authenticate: Unknown 401  (401 bad_auth_token)

    removed remote 'b2' again, since setup did not finish

error could not authenticate, and no --bucket was given to test directly.
```

---

## Options

Both scripts take the same options, in each platform's usual style.

| macOS / Linux | Windows | What it does |
|---|---|---|
| `-r, --remote NAME` | `-Remote NAME` | Name of the rclone remote. Default `b2`. |
| `--key-id ID` | `-KeyId ID` | B2 keyID. Else `$B2_KEY_ID`, else prompts. |
| `--app-key KEY` | `-AppKey KEY` | B2 applicationKey. Else `$B2_APP_KEY`, else prompts without echo. |
| `-b, --bucket NAME` | `-Bucket NAME` | Bucket to verify read/write against. **Recommended** — see below. |
| `--create-bucket` | `-CreateBucket` | Create the bucket if it doesn't exist. |
| `--force` | `-Force` | Replace an existing remote of the same name without asking. |
| `--no-install` | `-NoInstall` | Fail rather than offer to install rclone. |
| `-y, --yes` | `-Yes` | Assume yes to prompts. For scripts and CI. |
| `-h, --help` | `Get-Help .\connect.ps1` | Usage. |

Non-interactive, for a provisioning script:

```bash
B2_KEY_ID=005... B2_APP_KEY=K005... ./connect.sh --bucket my-bucket --yes
```

```powershell
$env:B2_KEY_ID='005...'; $env:B2_APP_KEY='K005...'
.\connect.ps1 -Bucket my-bucket -Yes
```

Multiple remotes are fine — `--remote b2personal`, `--remote b2work`, and so on.

---

## Now what?

You have a working remote called `b2`. Everything from here is plain rclone.

```bash
rclone ls b2:my-bucket                          # list what's there
rclone copy ~/Documents b2:my-bucket/Documents  # upload, never deletes
rclone copy b2:my-bucket/Documents ~/restored   # download

rclone sync ~/Documents b2:my-bucket/Documents --dry-run   # preview
rclone sync ~/Documents b2:my-bucket/Documents             # then for real

rclone check ~/Documents b2:my-bucket/Documents            # verify by hash
```

On Windows, swap `~/Documents` for `$env:USERPROFILE\Documents`.

Worth adding to real transfers:

```bash
rclone sync ~/Documents b2:my-bucket/Documents \
  --progress \
  --transfers 8 \
  --fast-list \
  --exclude '.DS_Store' --exclude 'node_modules/**'
```

`--fast-list` matters on B2: it fetches directory listings in bulk, which is both faster and fewer billable class-C API calls on large trees.

**`copy` adds. `sync` mirrors.** `sync` deletes anything at the destination that is not at the source — that is the whole point of it, and it is also how people lose backups. Preview with `--dry-run` every time.

---

## Three things about B2 that catch people out

These are the reasons this script exists rather than a one-line `rclone config create` in the README.

### A bucket-scoped key cannot list your buckets

`rclone lsd b2:` needs the `listBuckets` capability, which keys restricted to a single bucket do not have. So this is *expected* and not a sign of a bad key:

```
ERROR : error listing: Unknown 401  (401 unauthorized)
NOTICE: Failed to lsd with 2 errors: last error was: Unknown 401  (401 unauthorized)
```

Name the bucket and everything works fine:

```bash
rclone ls b2:my-bucket        # works
rclone lsd b2:                # 401, and that's correct
```

Note the difference between the two 401s you can get: `401 unauthorized` here means the key is valid but lacks a capability, whereas `401 bad_auth_token` means the credentials themselves are wrong.

The script knows this. If you pass `--bucket` it treats a failed bucket listing as a warning and tests the bucket directly instead.

### Deleting a file on B2 doesn't delete it

By default rclone's B2 backend does a *soft* delete: the file stops being visible but the version stays in the bucket, and **you keep paying for those bytes forever**. It also means a bucket you have "emptied" still refuses to be deleted:

```
failed to delete bucket: Cannot delete non-empty bucket (400 cannot_delete_non_empty_bucket)
```

That soft delete is a feature — it is your undelete window — but it needs an expiry date. Set one per bucket, once:

```bash
rclone backend lifecycle b2:my-bucket -o daysFromHidingToDeleting=30
```

Now hidden versions are cleaned up after 30 days and you stop paying for them. Requires rclone 1.65 or newer.

(This is also why the script's probe object is removed with `--b2-hard-delete`. Verifying a connection should leave your bucket exactly as it found it, and a normal delete would have left a permanent hidden version behind.)

### Bucket names are globally unique

Not unique to your account — unique across all of Backblaze. `backup`, `photos` and `data` went years ago. Use something like `yourname-hostname-backup`.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| `401 bad_auth_token` | Wrong keyID or applicationKey, or they're swapped. The keyID is the short one. |
| `401 unauthorized` on `rclone lsd b2:` | Key is valid but scoped to one bucket. Normal — name the bucket instead of listing. |
| `cannot write to it` from the script | The key is read-only. Check its permissions in the B2 console. |
| `403 cap_exceeded` | You've hit a cap set on the key or account, often the free-tier download cap. |
| `Cannot delete non-empty bucket` | Hidden versions remain. `rclone cleanup b2:my-bucket`, then retry. |
| `bucket is not reachable` | It doesn't exist (use `--create-bucket`) or the key is scoped to a different one. |
| Windows: `cannot be loaded because running scripts is disabled` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| `rclone: command not found` after install | Open a new terminal so PATH is picked up. |

To start over, delete the remote and re-run:

```bash
rclone config delete b2
```

---

## About your credentials

Worth knowing, because it is not obvious:

- rclone stores your applicationKey **in plaintext** in `rclone.conf`. It is not obscured the way rclone obscures password fields for some other backends. The file is created `0600` (owner-only), which is the actual protection.
- Find the file with `rclone config file`. Back it up somewhere safe, but not into the B2 bucket it unlocks.
- You can encrypt the whole config with a passphrase: `rclone config encryption set`. You'll then be asked for it on every rclone run, which is good for a laptop and awkward for a cron job.
- Both scripts pass the key to `rclone config create` as a command-line argument, so on a **shared multi-user machine** it is briefly visible in `ps`. rclone offers no way to avoid this. On a single-user machine it's a non-issue.
- Prefer a per-bucket application key over the master key. The master key can't be scoped and can't be rotated without breaking everything using it at once.

---

## Requirements

- **rclone** — any reasonably current version for setup and transfers; 1.65 or newer for the `lifecycle` command. The script installs it if missing, via Homebrew (macOS), rclone's official installer (Linux), or winget / scoop / choco (Windows).
- **macOS / Linux**: bash. Tested on bash 3.2, which is what macOS still ships, through bash 5.
- **Windows**: Windows PowerShell 5.1 (included in Windows 10 and 11) or PowerShell 7.
- A Backblaze B2 account. The [first 10 GB are free](https://www.backblaze.com/cloud-storage/pricing).

---

## Tests

There are behaviour tests that need no Backblaze account — they cover argument validation, the refusal paths, and that a remote which fails verification really is rolled back:

```bash
RCLONE_CONFIG=/tmp/scratch.conf ./.github/smoke.sh ./connect.sh
```

```powershell
$env:RCLONE_CONFIG = "$env:TEMP\scratch.conf"
./.github/smoke.ps1 -Script ./connect.ps1
```

CI runs both on Linux, macOS (bash 3.2 and 5) and Windows (PowerShell 5.1 and 7).

## Scope

This connects rclone to B2 and verifies it. That's all it does — no scheduling, no filter sets, no backup policy.

If you want to work out *what* to back up first — what's actually eating your disk, what's cache and junk that shouldn't go to the cloud, what it will cost per month — see [**backblaze-b2-backup-audit**](https://github.com/adamsiwiec1/backblaze-b2-backup-audit), which audits a machine, analyses it, and generates the filter sets. Use this repo to get connected, that one to decide what crosses the wire.

## License

MIT. See [LICENSE](LICENSE).
