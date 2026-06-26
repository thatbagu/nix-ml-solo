# File Sync

## What `sync` does

`sync` keeps your local project directory and the EC2 instance in sync. It combines two mechanisms:

1. **Mutagen** — bidirectional real-time file sync between local and `/home/ml/project` on EC2
2. **Nix cache push** — if the devenv profile changed since the last sync, pushes the new Nix closure to the S3 binary cache

`sync` is called automatically by `train`, `deploy`, and `jupyter` in cloud mode. You rarely need to run it manually.

## How mutagen works

Mutagen watches both sides for changes and syncs in real time. Changes on your laptop appear on EC2 within seconds, and vice versa. This means:

- Edit a file locally → it's immediately available on EC2
- A training job on EC2 writes output files → they appear locally
- Notebook outputs executed on EC2 sync back for local review

The mutagen session is named after the project (`TF_VAR_project`). Only one session runs at a time.

```sh
sync-ec2-status    # show session state, connection, conflicts
sync-ec2-stop      # terminate the session
```

## SSH config for mutagen

Mutagen connects to EC2 via SSH. The sync command writes a host entry to `~/.ssh/config.d/<project>` each time it runs:

```
Host nix-ml-solo-ec2
  HostName <current-ec2-ip>
  User ml
  IdentityFile /home/you/.ssh/nix-ml-solo
  IdentitiesOnly yes
  IdentityAgent none
```

The EC2 IP is dynamic (changes on instance restart), so the config is regenerated on every `sync` call.

## Nix cache push

When the devenv profile symlink changes (i.e. you ran `direnv reload` after editing `devenv.nix`), `sync` calls `nix-sync` to push the new closure to S3. EC2 pulls from the same bucket during `nixos-rebuild`, so it doesn't rebuild packages locally that you've already built.

The stamp file `.devenv-configs/.last-synced-profile` records the last pushed profile hash to avoid redundant pushes.

## Manual sync operations

```sh
nix-sync                           # push current devenv profile to S3 cache
nix-cache-push /nix/store/<hash>   # push a specific store path
nix-cache-pull /nix/store/<hash>   # pull a specific store path
```

The S3 bucket for the cache is read from `tofu output nix_cache_bucket` — requires `tf-apply` to have run first.

## Gitignore and sync

Files in `.gitignore` are still synced by mutagen. If you want to exclude files from the EC2 sync, add them to a `.mutagenignore` file in the project root:

```
.git/
.direnv/
.devenv/
*.pyc
__pycache__/
```
