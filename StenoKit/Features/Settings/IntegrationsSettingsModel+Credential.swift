import Foundation

/// The Integrations pane's credential half: §8's rules, in the file that owns them.
///
/// Split from `IntegrationsSettingsModel` for `AISettingsModel+Credential`'s
/// reason — the two halves are separate subjects, and one file carrying both runs
/// past SwiftLint's 400-line limit. This is one type in two files.
extension IntegrationsSettingsModel {
    /// Read the stored credential into the fields (D-218).
    ///
    /// **Site, email and expiry are prefilled; the token never is.** None of the
    /// first three is a secret, and a user who cannot see which site is configured
    /// cannot fix a typo in it. §8 and the second acceptance criterion cover the
    /// fourth.
    func load() {
        do {
            guard let stored = try credentials.credential() else {
                storedCredential = .absent
                return
            }
            storedCredential = .present(
                site: stored.site, email: stored.email, expiresAt: stored.expiresAt)
            site = stored.site
            email = stored.email
            if let expiry = stored.expiresAt {
                expiresAt = expiry
                recordsExpiry = true
            } else {
                recordsExpiry = false
            }
        } catch {
            // Not "absent": saying no credential is stored when the read was
            // refused is a claim about the user's Keychain that Steno cannot make.
            storedCredential = .unreadable(Self.detail(for: error))
            credentialProblem =
                "macOS could not read your stored credential: "
                + "\(Self.detail(for: error))."
        }
    }

    /// Store what is in the fields (§8: Keychain only).
    ///
    /// **The token is read back from the Keychain when the field is empty**
    /// (D-218). All four values live in one Keychain item (D-190), so changing only
    /// the site rewrites the whole item — which needs the token. It is a local here
    /// and never becomes a property of this type.
    ///
    /// Whitespace is trimmed on all three text fields, because the common way to
    /// produce any of them is a paste from a browser.
    public func saveCredential() {
        let trimmedSite = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSite.isEmpty else {
            credentialProblem = "Enter your Atlassian site, like acme.atlassian.net."
            return
        }
        // **Refused here, before anything is stored or sent** (D-190, D19). This
        // credential travels as HTTP Basic, so a mistyped host would send the user's
        // work token wherever it named. `AtlassianLogin` refuses on the same
        // function, so the CLI and the pane cannot disagree about what a usable site
        // is.
        guard AtlassianCredential.cloudHost(in: trimmedSite) != nil else {
            credentialProblem =
                "\"\(trimmedSite)\" is not an Atlassian Cloud site. Steno only talks to "
                + "*.atlassian.net, so your token is never sent anywhere else."
            return
        }
        guard !trimmedEmail.isEmpty else {
            credentialProblem = "Enter the email address of your Atlassian account."
            return
        }

        guard let token = resolvedToken() else { return }

        let expiry = recordsExpiry ? expiresAt : nil
        do {
            try credentials.store(
                AtlassianCredential(
                    site: trimmedSite, email: trimmedEmail, apiToken: token, expiresAt: expiry))
        } catch {
            credentialProblem =
                "macOS refused to store your credential: "
                + "\(Self.detail(for: error))."
            return
        }

        credentialProblem = nil
        tokenEntry = ""
        site = trimmedSite
        email = trimmedEmail
        storedCredential = .present(site: trimmedSite, email: trimmedEmail, expiresAt: expiry)
        // Every previous verdict described a credential that is no longer the stored
        // one. A result that outlived its credential is worse than none.
        forgetTestResults()
    }

    /// The token to store: what the user typed, or the stored one for a partial edit.
    ///
    /// **Extracted so `saveCredential()` fits SwiftLint's 50-line function budget**,
    /// and it reads better for it: this is the one decision in the save that is about
    /// the secret rather than about the form.
    ///
    /// `nil` means "store nothing", with the reason already in `credentialProblem` —
    /// the shape `DataSettingsModel.chooseFolder` uses for a refusal.
    private func resolvedToken() -> String? {
        let typed = tokenEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }

        do {
            guard let stored = try credentials.credential() else {
                credentialProblem = "Paste your API token — there isn't one stored yet."
                return nil
            }
            // The one place a stored token is read in order to be written again. It
            // goes no further than this scope: the caller hands it straight to
            // `store(_:)`, and no property of this type can hold it (D-218).
            return stored.apiToken
        } catch {
            // **Not treated as "no token".** Storing a credential built from a failed
            // read would write an empty token over a working one.
            credentialProblem =
                "macOS could not read your stored credential, so Steno "
                + "didn't change it: \(Self.detail(for: error))."
            return nil
        }
    }

    /// Delete the stored credential (§8's only removal path in this pane).
    ///
    /// **The enable flags are left alone**, for `removeKey`'s reason: a toggle is
    /// not a secret, and a user who rotates a token should not find their
    /// integrations silently switched off. The connectors report `.notConfigured`
    /// in the interval, which is the sentence that sends them back here.
    public func removeCredential() {
        do {
            try credentials.delete()
        } catch {
            credentialProblem =
                "macOS refused to remove your credential: "
                + "\(Self.detail(for: error))."
            return
        }
        credentialProblem = nil
        tokenEntry = ""
        site = ""
        email = ""
        recordsExpiry = false
        storedCredential = .absent
        forgetTestResults()
    }

    /// Drop whatever is in the token field without storing it.
    ///
    /// Called by the pane on appear and on disappear, which is what makes "the field
    /// is empty on every appearance" true of a model that outlives every appearance
    /// (D-157's rule, applied to this credential).
    public func forgetEntry() {
        tokenEntry = ""
    }

    /// What is safe to render about an error that is not known to be tame.
    ///
    /// A `KeychainError` is an `OSStatus` and a case name. Anything else could be an
    /// `EncodingError` quoting the value it failed on — which here is the whole
    /// credential — so only its type name is shown (§8).
    static func detail(for error: any Error) -> String {
        KeychainErrorDetail.of(error)
    }
}
