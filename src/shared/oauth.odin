package shared

// Auth provider presets, known to both sides: the server derives endpoints
// and scopes from them, the client renders the admin panel and login
// buttons. `issuer` is the default ("" = the admin must enter the instance
// URL). `hint` is a short setup note shown in the admin panel.

OAuth_Provider_Kind :: enum {
	OIDC,    // full OpenID Connect with discovery
	GitHub,  // plain OAuth2 + GitHub API (no OIDC)
	Discord, // plain OAuth2 + Discord API (no OIDC)
}

OAuth_Preset :: struct {
	id:     string,
	label:  string,
	kind:   OAuth_Provider_Kind,
	issuer: string,
	scopes: string,
	hint:   string,
}

OAUTH_PRESETS := [?]OAuth_Preset{
	{
		id = "google", label = "Google", kind = .OIDC,
		issuer = "https://accounts.google.com", scopes = "openid email profile",
		hint = "Google Cloud Console → Anmeldedaten → OAuth-Client-ID (Typ: Desktop-App)",
	},
	{
		id = "github", label = "GitHub", kind = .GitHub,
		scopes = "read:user user:email",
		hint = "GitHub → Settings → Developer settings → OAuth Apps · Callback-URL: http://127.0.0.1/callback",
	},
	{
		id = "gitlab", label = "GitLab", kind = .OIDC,
		issuer = "https://gitlab.com", scopes = "openid email profile",
		hint = "GitLab → Applications · bei self-hosted die Instanz-URL als Issuer eintragen",
	},
	{
		id = "microsoft", label = "Microsoft", kind = .OIDC,
		issuer = "https://login.microsoftonline.com/common/v2.0", scopes = "openid email profile",
		hint = "Entra ID → App-Registrierung (mobile & native Apps) · Single-Tenant: eigenen Issuer eintragen",
	},
	{
		id = "discord", label = "Discord", kind = .Discord,
		scopes = "identify email",
		hint = "Discord Developer Portal → Applications → OAuth2",
	},
	{
		id = "slack", label = "Slack", kind = .OIDC,
		issuer = "https://slack.com", scopes = "openid email profile",
		hint = "Slack API → Your Apps → OpenID Connect (Sign in with Slack)",
	},
	{
		id = "zitadel", label = "Zitadel", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Zitadel-Konsole → Projekt → App (Typ: Native, PKCE) · Issuer = Instanz-URL",
	},
	{
		id = "keycloak", label = "Keycloak", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Issuer = https://<host>/realms/<realm>",
	},
	{
		id = "authentik", label = "Authentik", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Issuer = https://<host>/application/o/<slug>/",
	},
	{
		id = "okta", label = "Okta", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Issuer = https://<org>.okta.com bzw. der Authorization-Server",
	},
	{
		id = "auth0", label = "Auth0", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Issuer = https://<tenant>.auth0.com",
	},
	{
		id = "oidc", label = "OpenID Connect", kind = .OIDC,
		scopes = "openid email profile",
		hint = "Beliebiger OIDC-Provider mit Discovery · Issuer-URL eintragen",
	},
}

oauth_preset :: proc(id: string) -> ^OAuth_Preset {
	for &p in OAUTH_PRESETS {
		if p.id == id {
			return &p
		}
	}
	return nil
}
