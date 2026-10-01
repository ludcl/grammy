# Grammy

A personal, native macOS writing assistant for selected text. Built with SwiftUI and AppKit, for Apple Silicon and macOS 26 (Tahoe) or later.

Select a draft in Slack Desktop → **Services → Grammy: Improve message** → review the suggestion → **Replace**, **Regenerate**, or **Cancel**. A global **Control–Option–Command–G** shortcut opens the same preview. A menu-bar action also lets you paste a message manually and copy its suggestion.

## Build and run

From this directory:

```sh
bash scripts/build.sh
open dist/Grammy.app
```

The script uses the installed Swift toolchain and signs with the sole installed Developer ID Application identity when available; otherwise it creates an ad-hoc-signed development app. No external packages or backend are needed. You can open `Package.swift` in Xcode to work on the code; use the bundled build script to assemble the `.app` with its Services registration.

For the most predictable Services discovery, place the built app in `~/Applications` or `/Applications`, launch it once, and restart Slack. In **System Settings → Keyboard → Keyboard Shortcuts → Services → Text**, enable **Grammy: Improve message** if needed. Right-click placement depends on the source editor. Also check **Slack → Services** in the macOS menu bar.

For the global shortcut, Slack emoji capture, and Replace, enable **Grammy** under **System Settings → Privacy & Security → Accessibility**. A consistent Developer ID signature and installation path help avoid permission resets between builds. Ad-hoc signatures are tied to each build: after rebuilding, macOS may show an enabled Accessibility toggle while denying access. Refresh the grant for the new app in that case. The development shortcut is fixed to Control–Option–Command–G.

## Connect ChatGPT

Choose **Continue with ChatGPT** in Grammy Settings. Select your account/workspace and authorize plan usage in the system browser. Grammy discovers the models available to that account; you can change the selected model in Settings.

This uses the documented preview for ChatGPT plan usage in local/open-source apps, not an API key or credentials copied from Codex. Enterprise workspaces may restrict this integration. A successful build does not establish your account's eligibility. The allowance described as “1,000 monthly tokens” must be checked in your account: credits and tokens are different units, and Grammy does not estimate a currency cost from that number.

There is **no paid OpenAI API fallback**. If enabled, the Google AI Studio fallback described below can handle ChatGPT availability errors. A failed request always leaves the draft unchanged until you accept a completed suggestion.

Authentication uses OAuth authorization code + PKCE, state and nonce validation, verified RS256 ID-token signatures from OpenAI's published JWKS, and serialized refreshes. Credentials are kept in macOS Keychain. The browser callback listens only on `127.0.0.1` for at most three minutes. A future signing-algorithm change fails closed and will need an update.

## Google AI Studio fallback

Grammy 0.2 adds **gemini-3.5-flash-lite** as an optional fallback. In Settings, paste your Google AI Studio API key into the secure field and choose **Save key & enable fallback**. The key is stored in a separate, device-only Keychain entry; it is never bundled in the app or written to preferences. Saving clears the input field. You can replace or remove the key at any time.

ChatGPT remains first. If it is disconnected, its account/model is unavailable, it returns an authentication/quota/server error, or a network connection fails, Grammy tries Gemini once when fallback is enabled. Any partial ChatGPT output is discarded. The preview identifies Gemini when it is used. Cancelling a rewrite never starts a fallback request. Content refusals and failed emoji validation do not trigger fallback.

The exact model is fixed to `gemini-3.5-flash-lite`; a missing-model error is shown rather than silently using a different model. Google receives the selected draft, correction instructions, and the latest alternative during regeneration. Google AI Studio quotas, billing, and data-handling terms apply separately from your ChatGPT subscription. There is still no paid OpenAI API fallback.

**Test connection** sends one short synthetic English message to Gemini and checks that the response completed and preserved its emoji. Saving a key alone does not make a network request. Disable **Use Gemini when ChatGPT is unavailable** to retain the saved key without automatic fallback.

## Behavior and limits

- No keystroke collection, background draft scanning, Slack token, bot, or workspace-history access.
- Opening a menu does not send text. Choosing the rewrite command or Regenerate does.
- Only the selected passage is sent to the active provider; regeneration also sends the latest alternative and correction instructions.
- Emoji graphemes and `:shortcodes:` must match the original before Replace or Copy is enabled.
- Suggestions can be edited in the preview. Rewrites are accepted only after the API signals completion (OpenAI `response.completed` or Gemini `STOP`).
- If the first response repeats the draft, Grammy automatically requests one correction pass from the same provider before completing the preview. Already-correct text may remain unchanged; the follow-up never loops.
- Services captures rich clipboard text after returning from the callback when Accessibility is enabled, so Electron can process Copy. It remembers the source app and checks the selected text against the Services input, then guards the complete draft and selection before Replace. The Service accepts input only; it never returns text for automatic insertion. Only the reviewed Replace action changes the source draft. Without Accessibility, complete Services input can still generate a suggestion to copy.
- Slack's Services input may contain unlabeled emoji image placeholders. Reading those requires Accessibility and a checked Copy operation; incomplete emoji text is never sent to a provider. Slack’s native Chromium clipboard data preserves its code spans and emoji objects; HTML emoji labels and the Unicode plain-text flavor also retain emojis alongside rich formatting. The first suggestion is requested automatically when the preview opens.
- The shortcut checks the original editor, complete value, selected range, and selected text before replacement. It refuses a stale target.
- With Accessibility, Grammy invokes the source app’s Copy and Paste commands through Accessibility, with process-targeted Cmd-C/Cmd-V as a fallback. It verifies the source selection and that Paste took effect. It never presses Return. The clipboard is restored after one second only if it was not changed by another app. Clipboard-manager history is outside Grammy's control.
- Inline code, bold, italics, underline, strikethrough and links are retained when the source provides RTF or semantic HTML. Code is protected from rewriting. Existing Markdown code delimiters are also checked. Pale yellow marks added/changed words in the suggestion, including manual edits; deleted words have no suggestion span. Highlight colors are display-only.
- Review complex lists, mentions and custom emoji objects: app-specific metadata is not reconstructed. Editors that provide only plain text cannot supply invisible rich formatting.
- Services may work in other editors; universal app compatibility is not claimed.
- No draft history, analytics, or message logging. Drafts and suggestions exist in process memory. `store: false` disables Responses storage; it is not a claim about all provider-side retention. Workspace/provider data rules still apply.

## Validate

```sh
bash scripts/test.sh
open dist/Grammy.app --args --sample
```

Tests cover complex emoji preservation, failed/incomplete responses, request constraints, PKCE, OAuth callback validation, JWT signatures/claims, the exact Gemini model and header authentication, fallback success/failure/cancellation, rich HTML/RTF round trips, protected code, style/link preservation and Unicode-aware change highlighting. The sample preview is explicitly labeled and makes no model request.

Manual acceptance checklist (use a disposable draft, never a sent message):

1. Sign in with your own ChatGPT account. Confirm a model catalog loads.
2. In Slack, type `hey team, i wont be able to joins today 😅 :thumbsup:` and select it.
3. Invoke Services. Confirm the preview, emoji preservation, Regenerate, and Cancel.
4. Invoke again and Replace. Confirm only selected text changed and nothing was sent. Try Undo in Slack.
5. Repeat via the global shortcut. While the preview is open, change the source draft or selection. Replace must refuse the changed target.
6. Test multiline text, Unicode emoji, custom emojis, mentions, linked text, and code blocks separately. Confirm `stage` and `develop` retain inline-code formatting, and yellow highlights are never pasted.
7. Check a second editor such as TextEdit. Compatibility is determined per editor.

## Signing and sharing

The build script automatically uses an installed Developer ID Application identity when there is exactly one. If you have several, provide the exact identity locally:

```sh
GRAMMY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build.sh
```

That enables hardened-runtime signing. Notarization is a separate distribution step; no app has been submitted to Apple by this project. Do not distribute the ad-hoc prototype as a notarized release. Everyone installs their own copy and signs in with their own account. No credentials are bundled. This repository has no publishing or open-source license decision yet.

## Sources

- [ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Account sessions and refresh](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and streaming](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple Services](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html)

- [Gemini 3.5 Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)
- [Gemini generateContent API](https://ai.google.dev/api/generate-content)
