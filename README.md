# Codex Webview Fix

An unofficial temporary workaround for the Codex VS Code extension startup
failure tracked in [openai/codex#37458](https://github.com/openai/codex/issues/37458):

```text
Codex could not start
The extension couldn't load its resources.
```

The message does not always mean that static files are missing. In affected
builds, the extension host can replace the webview with an error page when the
webview does not send its `ready` message within 30 seconds. This workaround
moves that message to the point where the webview runtime and host message
channel are ready, without waiting for later route, authentication, provider,
or feature-data initialization.

The current script has been validated against `openai.chatgpt 26.803.61601`.
It intentionally fails closed when a newer bundle no longer matches the
validated structure.

## Platform support

Only Windows is currently supported and tested. Pull requests that add safe,
validated support for other platforms are welcome.

## Usage

1. Close every VS Code, VS Code Insiders, and Positron window.
2. Open PowerShell in this repository.
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Apply-CodexWebviewReadinessFix.ps1
   ```

4. Reopen the editor. If it was not fully closed, run
   `Developer: Reload Window` from the command palette.

The script discovers the active `openai.chatgpt` extension from the editor's
extension registry, validates the expected bundle structure, creates a backup,
and then applies the patch.

If more than one installation is active or discovery is ambiguous, select the
extension directory explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-CodexWebviewReadinessFix.ps1 `
  -ExtensionPath "<path-to-openai.chatgpt-extension>"
```

Common locations include:

```text
%USERPROFILE%\.vscode\extensions\openai.chatgpt-<version>-win32-x64
%USERPROFILE%\.vscode-insiders\extensions\openai.chatgpt-<version>-win32-x64
%USERPROFILE%\.positron\extensions\openai.chatgpt-<version>-win32-x64
```

These locations are not hard-coded by the script.

## Asset graph fallback

Use the fallback only when the normal script completes successfully but the
failed startup log contains neither of these messages:

```text
React root render requested
[startup][renderer] webview runtime ready
```

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-CodexWebviewReadinessFix.ps1 `
  -ResetAssetGraph
```

This mode addresses failures that happen before the main application bundle is
executed. It:

- applies the readiness patch inside an isolated copy of the complete asset
  tree;
- removes static JavaScript `modulepreload` links while preserving stylesheet
  links and CSS preloading;
- changes `webview/index.html` to load the isolated asset namespace, preventing
  stale resources from reusing the old URLs; and
- records both the original index and the generated directory for rollback.

The fallback copies thousands of extension assets and therefore uses
additional disk space. Close all editor windows before applying it and reopen
affected windows sequentially. Do not use it for proxy, authentication, or
provider failures that occur after the application has started rendering.

## Restore

The apply script stores the original files and a manifest under:

```text
%LOCALAPPDATA%\CodexWebviewReadinessFix\backups\<version>-<time>
```

Restore the most recent backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\Restore-CodexWebviewReadinessFix.ps1
```

Restore a specific backup directory or manifest:

```powershell
powershell -ExecutionPolicy Bypass -File .\Restore-CodexWebviewReadinessFix.ps1 `
  -BackupPath "<backup-directory-or-manifest.json>"
```

Reinstalling the same extension version also restores the official files.

If the normal readiness patch was applied before the asset graph fallback, the
first restore removes only the fallback and returns to the readiness-patched
installation. Restore the earlier backup explicitly, or reinstall the
extension, to return all the way to the official files.

## Safety boundaries

- This repository does not redistribute modified extension JavaScript.
- The apply script changes only the identified entry chunk and delayed
  readiness reporter in the locally installed extension. The explicit asset
  graph fallback also updates `webview/index.html` and creates one isolated
  asset directory.
- The operation is idempotent. An already patched installation is not patched
  again.
- Every required code signature must match the expected structure. If an
  extension update changes that structure, the script stops before writing.
- Extension updates replace this workaround. Re-run the script only if the
  upstream issue still affects the new version and all validation checks pass.
- This project is not an official OpenAI release or support channel.
- This workaround does not address proxy failures or VS Code Web service-worker
  cache problems that can produce the same generic error message.

## Credits

- Bilibili: @石皮幼鸟
- GitHub: [@shipiyouniao](https://github.com/shipiyouniao)

## License

[MIT](LICENSE)
