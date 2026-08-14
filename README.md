# steno
Native macOS standup companion. Append-only task notes, enriched with Jira and Confluence, summarized by Claude.

## First-time setup

Steno builds entirely from the command line; Xcode's GUI is optional
(REQUIREMENTS.md §9).

```bash
make bootstrap                              # xcodegen, xcbeautify, swiftlint
```

Then, once per machine, give the build a stable signing identity. This is what
makes macOS remember the Accessibility permission the global hotkey needs — no
paid Apple Developer membership is involved (§6.1, §9.3):

1. Xcode → Settings → Accounts → add your Apple ID. This creates a free
   "Personal Team".
2. Read your Team ID out of the certificate:

   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
   ```

   The certificate text contains **three** different 10-character strings —
   `UID=`, the parenthetical in `CN=Apple Development: you@example.com
   (XXXXXXXXXX)`, and `OU=`. **Only `OU=` is the Team ID.** The command above
   already greps for it; if you read the ID by eye instead, it is easy to grab
   the `CN=` parenthetical by mistake — it looks just as plausible and is not
   the Team ID.
3. Copy the template and paste the ID in:

   ```bash
   cp Local.xcconfig.example Local.xcconfig
   # then edit Local.xcconfig, setting:
   #   DEVELOPMENT_TEAM = XXXXXXXXXX
   ```

`Local.xcconfig` is gitignored and never committed.

```bash
make run                                    # build and launch
make                                        # list every target
```

`make run` prints a launch line to the terminal, but that is a plain `print` —
everything logged through `os.Log` goes to the unified logging system and never
to stdout, `make run` or not. To watch it, run this in another terminal:

```bash
log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
```

### Signing troubleshooting

**"Certificate created but `0 valid identities found`."** Xcode's Manage
Certificates shows an `Apple Development` certificate, but
`security find-identity -v -p codesigning` reports zero valid identities. The
certificate is issued by **WWDR CA G3**, and the machine only has the **G1**
intermediate installed, which expired 2023-02-07 — the chain can't be built,
so the identity is present but invalid. Fix:

```bash
curl -fsSL -o /tmp/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security import /tmp/AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
```

To diagnose, run `security find-identity -p codesigning` (no `-v`) — if it
lists an identity that the `-v` (verified) form does not, the chain is the
problem, not the certificate itself.

**A keychain dialog reappears on every build.** The first `codesign` with a
new signing key raises a macOS dialog asking to allow access to the key.
Clicking **"Allow" grants only one use**, so the next build stalls on the same
dialog again — which looks exactly like a hung build. Click **"Always
Allow"** instead; that is what makes `make run` non-interactive from then on.
