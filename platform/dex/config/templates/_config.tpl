{{- define "dex.config" -}}
{{- $domain := required "baseDomain manquant (ex. 127.0.0.1.sslip.io)" .Values.baseDomain -}}
{{- $keycloak := printf "https://keycloak.%s/realms/kube" $domain -}}
{{- $internal := "" -}}
{{- with .Values.keycloakInternalURL }}{{ $internal = printf "%s/realms/kube" (trimSuffix "/" .) }}{{ end -}}
issuer: https://dex.{{ $domain }}

storage:
  type: kubernetes
  config:
    inCluster: true

oauth2:
  responseTypes: [code]
  skipApprovalScreen: true

expiry:
  idTokens: 1h

logger:
  format: json

enablePasswordDB: false

connectors:
  - type: oidc
    id: keycloak
    name: Keycloak
    config:
      {{- if $internal }}
      # dex passe par le Service, l'issuer des jetons reste l'URL publique
      issuer: {{ $internal }}
      issuerAlias: {{ $keycloak }}
      providerDiscoveryOverrides:
        tokenURL: {{ $internal }}/protocol/openid-connect/token
        jwksURL: {{ $internal }}/protocol/openid-connect/certs
        userInfoURL: {{ $internal }}/protocol/openid-connect/userinfo
      {{- else }}
      issuer: {{ $keycloak }}
      {{- end }}
      clientID: dex
      clientSecret: $KEYCLOAK_CLIENT_SECRET
      redirectURI: https://dex.{{ $domain }}/callback
      scopes: [profile, email]
      insecureEnableGroups: true
      # les comptes de l'équipe n'ont pas de nom, donc pas de claim name
      userNameKey: preferred_username

staticClients:
  - id: kubernetes
    name: Kubernetes
    secretEnv: KUBERNETES_CLIENT_SECRET
    redirectURIs:
      - http://localhost:8000
      - http://localhost:18000
  - id: argocd
    name: Argo CD
    secretEnv: ARGOCD_CLIENT_SECRET
    redirectURIs:
      - https://argocd.{{ $domain }}/auth/callback
      - http://localhost:8085/auth/callback
  - id: grafana
    name: Grafana
    secretEnv: GRAFANA_CLIENT_SECRET
    redirectURIs:
      - https://grafana.{{ $domain }}/login/generic_oauth
  - id: headlamp
    name: Headlamp
    secretEnv: HEADLAMP_CLIENT_SECRET
    redirectURIs:
      - https://headlamp.{{ $domain }}/oidc-callback
{{- end -}}
