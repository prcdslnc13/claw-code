//! Discovery of OAuth credentials stored by upstream Claude Code.
//!
//! `claw` does not implement an OAuth client of its own. Instead, when the
//! standard env-var paths (`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`) are
//! absent, it looks for credentials placed on disk (or in the macOS Keychain)
//! by an upstream Claude Code install on the same machine. The user logs in
//! with `claude auth login` once; `claw` then reuses the resulting tokens.
//!
//! Discovery order:
//!
//! 1. **`CLAUDE_CONFIG_DIR`** — if set, read `<dir>/.credentials.json`. This
//!    matches the `claude-f42` / `claude-work` bash-alias pattern that points
//!    upstream Claude Code at non-default config directories.
//! 2. **macOS Keychain** (Mac only) — `security find-generic-password -s
//!    "Claude Code-credentials" -w`. The stored password is itself the JSON
//!    blob `{"claudeAiOauth": ...}`.
//! 3. **`~/.claude/.credentials.json`** — the default upstream location on
//!    Linux / WSL2 (and Mac if Keychain lookup yielded nothing).
//!
//! A missing file or empty Keychain is **not** an error — the function returns
//! `Ok(None)` so callers can fall through to other auth strategies.

use std::fs;
use std::io;
use std::path::PathBuf;

use serde::Deserialize;

/// Subset of upstream Claude Code's stored OAuth credentials that `claw`
/// consumes. Upstream may add fields (e.g. `subscriptionType`,
/// `rateLimitTier`); they are ignored.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpstreamCredentials {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// Unix timestamp **in milliseconds** as stored by upstream Claude Code.
    /// Note this differs from claw's own [`OAuthTokenSet::expires_at`] which
    /// is in seconds — convert at the boundary if you need to compare.
    #[serde(default)]
    pub expires_at: Option<u64>,
    #[serde(default)]
    pub scopes: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct UpstreamCredentialsFile {
    #[serde(default, rename = "claudeAiOauth")]
    claude_ai_oauth: Option<UpstreamCredentials>,
}

/// Environment variable that, when set to any value, short-circuits
/// discovery and returns `Ok(None)`. Useful for forcing the env-var auth
/// path even when an upstream Claude Code install is present on the host
/// (and required by tests so they don't pick up the developer's real
/// credentials).
pub const DISCOVERY_DISABLE_ENV: &str = "CLAW_DISABLE_UPSTREAM_DISCOVERY";

/// Locate and parse upstream Claude Code's stored OAuth credentials.
///
/// Returns `Ok(None)` when no upstream credentials are present on this host
/// or when [`DISCOVERY_DISABLE_ENV`] is set. Errors propagate only on actual
/// I/O failures or malformed JSON.
pub fn discover_upstream_credentials() -> io::Result<Option<UpstreamCredentials>> {
    if std::env::var_os(DISCOVERY_DISABLE_ENV).is_some() {
        return Ok(None);
    }
    if let Some(path) = explicit_config_dir_path() {
        match read_credentials_file(&path)? {
            Some(creds) => return Ok(Some(creds)),
            None => return Ok(None),
        }
    }

    #[cfg(target_os = "macos")]
    {
        if let Some(creds) = discover_from_macos_keychain()? {
            return Ok(Some(creds));
        }
    }

    if let Some(path) = default_credentials_path() {
        if let Some(creds) = read_credentials_file(&path)? {
            return Ok(Some(creds));
        }
    }

    Ok(None)
}

/// `<CLAUDE_CONFIG_DIR>/.credentials.json` if the env var is set, else `None`.
fn explicit_config_dir_path() -> Option<PathBuf> {
    std::env::var_os("CLAUDE_CONFIG_DIR").map(|dir| PathBuf::from(dir).join(".credentials.json"))
}

/// `<HOME>/.claude/.credentials.json` (or `<USERPROFILE>` on Windows) if a
/// home directory can be resolved.
fn default_credentials_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))?;
    Some(
        PathBuf::from(home)
            .join(".claude")
            .join(".credentials.json"),
    )
}

fn read_credentials_file(path: &PathBuf) -> io::Result<Option<UpstreamCredentials>> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if contents.trim().is_empty() {
        return Ok(None);
    }
    parse_credentials_blob(&contents).map(Some)
}

#[cfg(target_os = "macos")]
fn discover_from_macos_keychain() -> io::Result<Option<UpstreamCredentials>> {
    use std::process::Command;

    // `-w` prints just the password value (the JSON blob) on stdout.
    let output = match Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            "Claude Code-credentials",
            "-w",
        ])
        .output()
    {
        Ok(output) => output,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };

    if !output.status.success() {
        // exit 44 ("could not be found") is the common no-creds case; treat
        // any non-success as "no upstream creds in keychain" rather than
        // erroring — the caller will fall through to file discovery.
        return Ok(None);
    }

    let blob = String::from_utf8(output.stdout)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    let blob = blob.trim_end_matches('\n').trim_end_matches('\r');
    parse_credentials_blob(blob).map(Some)
}

fn parse_credentials_blob(blob: &str) -> io::Result<UpstreamCredentials> {
    let file: UpstreamCredentialsFile = serde_json::from_str(blob)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    file.claude_ai_oauth.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "upstream credentials blob missing 'claudeAiOauth' object",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_BLOB: &str = r#"{
        "claudeAiOauth": {
            "accessToken": "tok-access",
            "refreshToken": "tok-refresh",
            "expiresAt": 1777085235270,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "tier-x"
        }
    }"#;

    #[test]
    fn parses_real_upstream_blob_shape() {
        let creds = parse_credentials_blob(SAMPLE_BLOB).expect("parse");
        assert_eq!(creds.access_token, "tok-access");
        assert_eq!(creds.refresh_token.as_deref(), Some("tok-refresh"));
        assert_eq!(creds.expires_at, Some(1_777_085_235_270));
        assert_eq!(creds.scopes, vec!["user:inference", "user:profile"]);
    }

    #[test]
    fn ignores_extra_fields() {
        let blob = r#"{"claudeAiOauth": {"accessToken": "x", "newField": 42}}"#;
        let creds = parse_credentials_blob(blob).expect("parse");
        assert_eq!(creds.access_token, "x");
        assert_eq!(creds.refresh_token, None);
    }

    #[test]
    fn missing_claude_ai_oauth_is_an_error() {
        let blob = r#"{"someOtherKey": {}}"#;
        let err = parse_credentials_blob(blob).expect_err("should error");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn malformed_json_is_invalid_data() {
        let err = parse_credentials_blob("not json").expect_err("should error");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn empty_file_returns_none() {
        let dir = std::env::temp_dir().join(format!(
            "claw-upstream-creds-empty-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join(".credentials.json");
        std::fs::write(&path, "").expect("write");
        let result = read_credentials_file(&path).expect("read");
        assert_eq!(result, None);
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn missing_file_returns_none_not_error() {
        let path = std::env::temp_dir().join(format!(
            "claw-upstream-creds-missing-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        let result = read_credentials_file(&path).expect("read");
        assert_eq!(result, None);
    }
}
