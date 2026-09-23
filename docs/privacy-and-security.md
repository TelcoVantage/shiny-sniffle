# Privacy and Security

Survey exports from a contact-centre platform can contain personal data: what customers said,
when they called, and identifiers that link back to recordings and customer records. This
project is designed so it can be demonstrated publicly **without any of that data**.

## Rules for this repository

1. **Never commit production exports.** Only the synthetic file
   `sample-data/survey-responses.csv` belongs in source control.
2. **Never commit any of the following**, even in test fixtures, screenshots, issues, or pull requests:
   - API tokens, OAuth client IDs or secrets, access tokens, refresh tokens, passwords
   - Call recordings, transcripts, or screen recordings
   - ANI / DNIS (caller and dialled numbers) or any other phone numbers
   - Customer names, email addresses, postal addresses, account numbers
   - Employee or agent names, user IDs, or email addresses
   - Real conversation, participant, or survey IDs
   - Organisation names, tenant or region URLs, org IDs
   - Queue names, flow names, skills, or other internal configuration
3. **Use synthetic data in public repositories.** Sample identifiers in this project are
   deliberately fake (`nps-1001`, `sample-conv-0001`) and every utterance was written for the demo.
4. **Keep generated reports and raw exports out of Git.** The `.gitignore` already excludes
   `output/*`, `nps-audit-*` files, common export file names, audio files, transcripts, `.env` files,
   certificates, and `*.local.*` configuration. Check `git status` before every commit.
5. **Sanitise before sharing.** If a real export must be used to reproduce a bug, replace every
   identifier and rewrite every utterance before it leaves the approved environment. Prefer
   writing a new synthetic row that reproduces the same pattern.

## What the tool itself does

- Runs **entirely offline**. It makes no network calls and loads no remote resources.
- The HTML report is fully self-contained: embedded CSS, no JavaScript, no CDNs, no external
  images or fonts.
- The summary report records the **input file name only**, not the full path, so local user
  names and folder structures are not leaked into shared reports.
- Generated reports still contain utterances from the input file. Treat them with the same
  classification as the source export and delete them when no longer needed.
- The scripts are compatible with Constrained Language Mode, so they can run on endpoints locked
  down with AppLocker or WDAC without requesting policy exceptions.

## Future API integration

Version one deliberately has no API connector. A future optional connector must:

- Read credentials from **environment variables** or an **approved secret store**
  (for example Windows Credential Manager, a vault, or the platform's managed identity).
  **Never hard-code credentials**, and never accept secrets as plain command-line arguments that
  end up in shell history or process listings.
- Use the least-privileged OAuth client and scopes that can read survey data, and nothing more.
- Validate every API response explicitly (for example, confirm an `access_token` is present
  before continuing) instead of assuming success.
- Never log tokens, authorisation headers, or full response bodies.
- Write downloaded data only to git-ignored locations.
- Stay CLM-safe: no `.NET` static method calls, no `Add-Type`, no external modules.

## Reporting a security issue

If you find a way this project could expose sensitive data, please open an issue **without**
including any real data, or contact the maintainer privately through the repository.
