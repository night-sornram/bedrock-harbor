# Google Play session status

Accounts and Play observe the same application-owned `PlaySessionCoordinator`.
Saved cookies, tokens, backup credentials, remembered email addresses, and legacy
account metadata never prove authentication. On startup, a saved credential is
checked once in the background; local game launch does not wait for this check.

- No credentials: **Not signed in**.
- Candidate credentials: **Checking saved session**.
- Successful authenticated check: **Signed in**, labelled as restored when applicable.
- Explicit credential rejection: **Sign-in expired**.
- Offline, missing helper, timeout, or service failure: **Unable to verify**.

Authentication does not prove Minecraft ownership or download eligibility. A local
game makes Google Play optional and never completes the sign-in checklist item.
The remembered email on a legacy master-token record is not displayed as a verified
identity; identity is shown when returned by the access-token exchange.

The browser uses a separate cookie store for each attempt. Closing, cancelling,
or timing out returns a typed failure result without persisting partial credentials.
Sign-out cancels work and clears Harbor's Google cookie, token, CLI, backup, email,
and account stores. It leaves installations, worlds, profiles, and Microsoft sessions
alone. Generation checks discard responses from older attempts.

## Helper protocol

The bundled `gplayver --auth-check --save-auth --device device.conf` verifies the
credential without querying games, accepting store terms, or downloading content.
An OAuth candidate is supplied using `--access-token-file` with a private file,
never its literal value in argv. The helper runs in a private temporary directory.
Only a successful check commits its reusable session to Harbor's managed store.

Success exits with code 0 and emits `authentication verified`. Explicit rejection
exits with code 3. Transport and other authentication failures exit with code 2;
they must not erase credentials. Checks have a 30-second timeout and terminate on
cancellation. Raw authentication exceptions and token values are not shown in the UI.

## Validation

Run the full suite with the Xcode command in README. Coverage includes restored and
expired sessions, offline checks, cancelled and stale callbacks, storage cleanup,
other-provider accounts, subprocess cancellation, and both screen appearances.
Set `HARBOR_UI_SNAPSHOTS` to an existing output directory to save the light/dark
Accounts and Play fixtures while running the feature tests.

Real Microsoft-window timing and Google authentication still require a local game
installation and an interactive account. Unit-test timings do not establish the
one-second launch-preparation or three-second Microsoft-window performance targets.
