# Login über Auth-Provider (SSO)

Flurfunk kann die Anmeldung an externe Identity-Provider delegieren.
Admins aktivieren Provider unter **Verwaltung → Anmeldung**; auf der
Anmeldeseite des Clients erscheint dann pro aktivem Provider ein Button
(„Mit Google anmelden“ …). Beim ersten Login mit einem Provider-Konto
wird automatisch ein Flurfunk-Konto angelegt — auch wenn die
Registrierung geschlossen ist. Wer den Provider-Login nutzen darf,
steuert man also beim Provider (z. B. über die eigene Zitadel-Instanz),
nicht in Flurfunk.

## Wie der Flow funktioniert

1. Der Client öffnet einen Loopback-Port (RFC 8252) und fragt beim
   Flurfunk-Server eine Auth-URL an.
2. Der Server baut die URL (inkl. PKCE-Challenge und CSRF-State) und der
   Client öffnet sie im System-Browser.
3. Nach der Anmeldung leitet der Provider auf
   `http://127.0.0.1:<Port>/callback` um; der Client fängt den Code ab
   und reicht ihn an den Server weiter.
4. Der **Server** tauscht den Code gegen ein Token (das Client-Secret
   verlässt den Server nie), holt die Userinfo und meldet den Nutzer an.

Der Redirect-Port ist dynamisch — beim Provider muss deshalb eine
Loopback-Redirect-URI erlaubt sein (bei den meisten Anbietern der
App-Typ „Desktop“/„Native“).

## Provider einrichten

Gemeinsam für alle: **Client-ID** eintragen, optional **Client-Secret**
(PKCE-/Native-Apps brauchen oft keins), bei OIDC-Providern ohne festen
Dienst die **Issuer-URL** der eigenen Instanz.

| Provider | App-Typ / Ort | Hinweise |
|----------|---------------|----------|
| Google | Cloud Console → OAuth-Client, Typ **Desktop-App** | Loopback-Redirects sind bei Desktop-Apps automatisch erlaubt |
| GitHub | Settings → Developer settings → **OAuth Apps** | Callback-URL `http://127.0.0.1/callback` — GitHub ignoriert den Port bei Loopback. Client-Secret erforderlich |
| GitLab | Applications (gitlab.com oder self-hosted) | Self-hosted: Instanz-URL als Issuer eintragen |
| Microsoft | Entra ID → App-Registrierung, Plattform **Mobile & Desktop** | Default-Issuer ist `…/common/v2.0` (Multi-Tenant); Single-Tenant: eigenen Tenant-Issuer eintragen |
| Discord | Developer Portal → Applications → OAuth2 | Redirect `http://127.0.0.1:<Port>/callback` eintragen |
| Slack | api.slack.com → Your Apps → OpenID Connect | |
| Zitadel | Konsole → Projekt → App, Typ **Native** (PKCE) | Issuer = Instanz-URL (z. B. `https://firma.zitadel.cloud`) |
| Keycloak | Client im Realm anlegen | Issuer = `https://<host>/realms/<realm>` |
| Authentik | Application + OAuth2-Provider | Issuer = `https://<host>/application/o/<slug>/` |
| Okta | Applications → OIDC Native App | Issuer = `https://<org>.okta.com` bzw. Authorization-Server |
| Auth0 | Applications → Native | Issuer = `https://<tenant>.auth0.com` |
| OpenID Connect | beliebiger Provider mit Discovery | Issuer-URL eintragen; Button-Beschriftung ist anpassbar |

## Verhalten der Konten

- Provider-Konten werden über die stabile Provider-ID (`sub`)
  wiedererkannt, nicht über den Nutzernamen.
- Der Nutzername wird aus `preferred_username`/E-Mail abgeleitet und bei
  Kollision mit Suffix versehen (`mia.muster2`).
- OAuth-Konten haben **kein Passwort** — Passwort-Login schlägt fehl.
  Ein Admin kann per Passwort-Reset trotzdem eines setzen (danach gehen
  beide Wege).
- Deaktivierte Konten kommen auch über den Provider nicht mehr rein.
- Wird ein Provider deaktiviert, verschwindet der Button; bestehende
  Sitzungen bleiben gültig.

## Betrieb

Der Server braucht dafür ausgehendes HTTPS (libcurl + CA-Zertifikate;
im Docker-Image enthalten). Die Provider-Konfiguration liegt in
`<data>/oauth.json` (0600, enthält das Client-Secret).
