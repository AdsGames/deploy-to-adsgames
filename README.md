# Deploy to A.D.S. Games

Deploy action for releasing a game to A.D.S. Games.

## Inputs

project-id

> Name or game to deploy (i.e. brickbreaker)

version

> Version of the game to deploy (i.e. 1.0.0)

platform

> Platform of release (one of WINDOWS, LINUX, MAC or WEB)

build-dir

> Directory to deploy to (i.e. ./dist)

entry

> Index file to serve (web builds only) (i.e. index.html)

workload-identity-provider

> (optional) GitHub OIDC workload identity provider resource name. Defaults to the AdsGames provider.

service-account

> (optional) Service account to impersonate for bucket uploads. Defaults to the AdsGames games-deploy SA.

## Authentication

Uploads authenticate to Google Cloud Storage using GitHub OIDC (Workload
Identity Federation) — no long-lived keys. Calling workflows must grant the
`id-token` permission:

```yaml
permissions:
  id-token: write
  contents: read
```

Any repository owned by the `AdsGames` GitHub org is authorized to impersonate
the deploy service account.
