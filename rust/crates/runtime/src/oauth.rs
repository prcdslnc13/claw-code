//! OAuth credential storage and refresh-request shapes used by the API client.
//!
//! `claw` does not implement the browser-based OAuth login flow. Instead, it
//! reuses credentials stored by an upstream Claude Code install — see
//! [`crate::upstream_credentials`] for discovery. This module owns:
//!
//! * the persisted [`OAuthTokenSet`] shape that the API layer reads back on
//!   startup and rewrites after a refresh round-trip,
//! * the wire shape ([`OAuthRefreshRequest`]) the API layer POSTs to
//!   `console.anthropic.com/v1/oauth/token` to mint a new access token,
//! * platform-aware on-disk storage at `~/.claw/credentials.json` (0o600 on
//!   Unix; the file is namespaced under an `"oauth"` key so unrelated
//!   per-user keys can coexist).
//!
//! The full PKCE / loopback-callback flow that lived here previously was
//! removed in the upstream-credential-reuse refactor: there is no published
//! Anthropic OAuth provider for third-party CLIs, so generating an
//! authorization URL ourselves had no working endpoint to call.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::config::OAuthConfig;

/// Persisted OAuth access token bundle used by the CLI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OAuthTokenSet {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<u64>,
    pub scopes: Vec<String>,
}

/// Request body for refreshing an existing OAuth token set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OAuthRefreshRequest {
    pub grant_type: &'static str,
    pub refresh_token: String,
    pub client_id: String,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredOAuthCredentials {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_at: Option<u64>,
    #[serde(default)]
    scopes: Vec<String>,
}

impl From<OAuthTokenSet> for StoredOAuthCredentials {
    fn from(value: OAuthTokenSet) -> Self {
        Self {
            access_token: value.access_token,
            refresh_token: value.refresh_token,
            expires_at: value.expires_at,
            scopes: value.scopes,
        }
    }
}

impl From<StoredOAuthCredentials> for OAuthTokenSet {
    fn from(value: StoredOAuthCredentials) -> Self {
        Self {
            access_token: value.access_token,
            refresh_token: value.refresh_token,
            expires_at: value.expires_at,
            scopes: value.scopes,
        }
    }
}

impl OAuthRefreshRequest {
    #[must_use]
    pub fn from_config(
        config: &OAuthConfig,
        refresh_token: impl Into<String>,
        scopes: Option<Vec<String>>,
    ) -> Self {
        Self {
            grant_type: "refresh_token",
            refresh_token: refresh_token.into(),
            client_id: config.client_id.clone(),
            scopes: scopes.unwrap_or_else(|| config.scopes.clone()),
        }
    }

    #[must_use]
    pub fn form_params(&self) -> BTreeMap<&str, String> {
        BTreeMap::from([
            ("grant_type", self.grant_type.to_string()),
            ("refresh_token", self.refresh_token.clone()),
            ("client_id", self.client_id.clone()),
            ("scope", self.scopes.join(" ")),
        ])
    }
}

pub fn credentials_path() -> io::Result<PathBuf> {
    Ok(credentials_home_dir()?.join("credentials.json"))
}

pub fn load_oauth_credentials() -> io::Result<Option<OAuthTokenSet>> {
    let path = credentials_path()?;
    let root = read_credentials_root(&path)?;
    let Some(oauth) = root.get("oauth") else {
        return Ok(None);
    };
    if oauth.is_null() {
        return Ok(None);
    }
    let stored = serde_json::from_value::<StoredOAuthCredentials>(oauth.clone())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    Ok(Some(stored.into()))
}

pub fn save_oauth_credentials(token_set: &OAuthTokenSet) -> io::Result<()> {
    let path = credentials_path()?;
    let mut root = read_credentials_root(&path)?;
    root.insert(
        "oauth".to_string(),
        serde_json::to_value(StoredOAuthCredentials::from(token_set.clone()))
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
    );
    write_credentials_root(&path, &root)
}

pub fn clear_oauth_credentials() -> io::Result<()> {
    let path = credentials_path()?;
    let mut root = read_credentials_root(&path)?;
    root.remove("oauth");
    write_credentials_root(&path, &root)
}

fn credentials_home_dir() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("CLAW_CONFIG_HOME") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "HOME is not set (on Windows, set USERPROFILE or HOME, \
                 or use CLAW_CONFIG_HOME to point directly at the config directory)",
            )
        })?;
    Ok(PathBuf::from(home).join(".claw"))
}

fn read_credentials_root(path: &PathBuf) -> io::Result<Map<String, Value>> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            if contents.trim().is_empty() {
                return Ok(Map::new());
            }
            serde_json::from_str::<Value>(&contents)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
                .as_object()
                .cloned()
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "credentials file must contain a JSON object",
                    )
                })
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Map::new()),
        Err(error) => Err(error),
    }
}

fn write_credentials_root(path: &PathBuf, root: &Map<String, Value>) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        // Best-effort: tighten the config dir. Failure is non-fatal — the
        // per-file 0600 below is the actual guarantee against multi-user
        // snooping of OAuth tokens.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
        }
    }
    let rendered = serde_json::to_string_pretty(&Value::Object(root.clone()))
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let temp_path = path.with_extension("json.tmp");
    fs::write(&temp_path, format!("{rendered}\n"))?;

    // Restrict to owner read/write before publishing. The mode survives the
    // rename because rename(2) preserves the inode and its permission bits,
    // so the destination never exists with default-umask perms.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o600))?;
    }

    fs::rename(temp_path, path)
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{
        clear_oauth_credentials, credentials_path, load_oauth_credentials, save_oauth_credentials,
        OAuthConfig, OAuthRefreshRequest, OAuthTokenSet,
    };

    fn sample_config() -> OAuthConfig {
        OAuthConfig {
            client_id: "runtime-client".to_string(),
            authorize_url: "https://console.test/oauth/authorize".to_string(),
            token_url: "https://console.test/oauth/token".to_string(),
            callback_port: Some(4545),
            manual_redirect_url: Some("https://console.test/oauth/callback".to_string()),
            scopes: vec!["org:read".to_string(), "user:write".to_string()],
        }
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        crate::test_env_lock()
    }

    fn temp_config_home() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "runtime-oauth-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        ))
    }

    #[test]
    fn refresh_request_renders_form_params() {
        let config = sample_config();
        let refresh = OAuthRefreshRequest::from_config(&config, "refresh-token", None);
        assert_eq!(
            refresh.form_params().get("scope").map(String::as_str),
            Some("org:read user:write")
        );
        assert_eq!(
            refresh.form_params().get("grant_type").map(String::as_str),
            Some("refresh_token")
        );
    }

    #[test]
    fn oauth_credentials_round_trip_and_clear_preserves_other_fields() {
        let _guard = env_lock();
        let config_home = temp_config_home();
        std::env::set_var("CLAW_CONFIG_HOME", &config_home);
        let path = credentials_path().expect("credentials path");
        std::fs::create_dir_all(path.parent().expect("parent")).expect("create parent");
        std::fs::write(&path, "{\"other\":\"value\"}\n").expect("seed credentials");

        let token_set = OAuthTokenSet {
            access_token: "access-token".to_string(),
            refresh_token: Some("refresh-token".to_string()),
            expires_at: Some(123),
            scopes: vec!["scope:a".to_string()],
        };
        save_oauth_credentials(&token_set).expect("save credentials");
        assert_eq!(
            load_oauth_credentials().expect("load credentials"),
            Some(token_set)
        );
        let saved = std::fs::read_to_string(&path).expect("read saved file");
        assert!(saved.contains("\"other\": \"value\""));
        assert!(saved.contains("\"oauth\""));

        clear_oauth_credentials().expect("clear credentials");
        assert_eq!(load_oauth_credentials().expect("load cleared"), None);
        let cleared = std::fs::read_to_string(&path).expect("read cleared file");
        assert!(cleared.contains("\"other\": \"value\""));
        assert!(!cleared.contains("\"oauth\""));

        std::env::remove_var("CLAW_CONFIG_HOME");
        std::fs::remove_dir_all(config_home).expect("cleanup temp dir");
    }
}
