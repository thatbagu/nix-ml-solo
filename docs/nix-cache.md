# Nix Binary Cache

## What it is

A Nix binary cache stores pre-built Nix derivations so they don't need to be rebuilt from source. nix-ml-solo provisions a private S3 bucket as a binary cache shared between your laptop and the EC2 instance.

## Why it matters

When you run `nixos-rebuild` to update the EC2 instance, Nix needs to build (or fetch) every package in the closure. Without a cache, EC2 rebuilds locally what your laptop already built — wasting time and bandwidth. With the S3 cache:

1. Your laptop builds the devenv closure on `direnv reload`
2. `nix-sync` pushes that closure to S3
3. EC2 pulls pre-built packages from S3 during `nixos-rebuild`

The cache is also used by the `container-build` pipeline to avoid rebuilding Nix layers that are already in S3.

## Setup

The S3 bucket is created by `tf-apply`. After provisioning, configure the local Nix daemon to use it:

```sh
nix-cache-configure-local
```

This appends to `~/.config/nix/nix.conf`:

```
extra-substituters = s3://<project>-<env>-nix-cache?region=<region>
```

Restart the Nix daemon if needed:

```sh
sudo systemctl restart nix-daemon
```

## Pushing to the cache

```sh
nix-sync                           # push the current devenv profile closure
nix-cache-push /nix/store/<hash>   # push a specific store path and its dependencies
```

`sync` calls `nix-sync` automatically when the devenv profile changes.

## Pulling from the cache

Once configured as a substituter, Nix pulls from S3 automatically whenever it needs a path that exists there. You can also pull explicitly:

```sh
nix-cache-pull /nix/store/<hash>
```

## IAM permissions

The S3 cache bucket has IAM policies attached:

- The `<project>-deploy` IAM user has read/write access (for push from laptop)
- The EC2 instance role has read access (for pull during nixos-rebuild)

No extra configuration is needed.

## Cache invalidation

The cache is content-addressed by Nix store hash. There is no invalidation — a given store path always has the same content. Old paths accumulate in S3. Clean up with:

```sh
aws s3 rm s3://<project>-<env>-nix-cache --recursive
```

This clears the cache without breaking anything — Nix will just rebuild on the next operation.
