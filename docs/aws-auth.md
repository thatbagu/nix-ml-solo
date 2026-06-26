# AWS Authentication

## Two auth methods

The setup wizard offers two methods:

| Method              | Best for                | Credential lifetime  |
|---------------------|-------------------------|----------------------|
| IAM access keys     | Solo use, one developer | Long-lived (manual rotation) |
| IAM Identity Center | Teams, SSO              | Short-lived (auto-refresh)   |

## IAM access keys (default)

The wizard creates an IAM user named `<project>-deploy` with `AdministratorAccess` and generates access keys automatically. The keys are written to `.devenv-configs/.aws/credentials` (gitignored).

Environment variables set in the shell:

```sh
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_PROFILE=ml-solo
AWS_DEFAULT_REGION=us-east-1
```

No login command is needed. Keys are valid until you rotate or delete them.

To rotate keys:

```sh
setup    # re-runs the wizard, creates new keys, deletes the old ones
```

## IAM Identity Center (SSO)

For team use or when your organization requires federated authentication.

### Setup

1. Enable **IAM Identity Center** in your AWS account (AWS console → IAM Identity Center → Enable)
2. Create a user and assign the `AdministratorAccess` permission set
3. Note your **SSO start URL** (e.g. `https://my-org.awsapps.com/start`)
4. In the wizard, select **Identity Center** and enter:
   - SSO start URL
   - AWS account ID
   - Permission set role name (e.g. `AdministratorAccess`)

### Usage

SSO credentials expire after a few hours. Refresh them:

```sh
aws-login
```

This opens a browser to complete the SSO login flow and caches the temporary credentials. All subsequent AWS calls use the refreshed credentials automatically.

### Verifying credentials

```sh
aws-verify    # prints current caller identity (ARN, account ID, user ID)
```

Use this to confirm which credentials are active before running destructive operations like `teardown`.

## Credential storage

Credentials are stored in `.devenv-configs/.aws/` inside the project directory. This directory is gitignored. The devenv shell configures `AWS_SHARED_CREDENTIALS_FILE` to point here so the project-specific credentials don't conflict with credentials in `~/.aws/`.

## Bootstrap credentials

The wizard needs temporary admin credentials once to create the `<project>-deploy` IAM user. These are entered interactively and never saved to disk. After the IAM user is created, the bootstrap credentials are no longer used.

If you run `teardown` (which deletes the IAM user via aws-nuke) and then need to re-provision, you'll need bootstrap credentials again. Use root account credentials or another IAM admin user for this.
