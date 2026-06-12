package auth

import (
	"encoding/base64"
	"encoding/json"
	"strings"

	"go.temporal.io/server/common/authorization"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/log"
)

// emailPermissions maps Dex static user email addresses to Temporal permissions.
// Used as a fallback when the JWT has no "permissions" claim (e.g. Dex static passwords).
// Format per entry: "<namespace>:<role>" — same as the default claim mapper.
// Use "temporal-system" as namespace for system-level roles.
//
// For production IDPs (Okta, Auth0, Keycloak) that issue JWTs with a "permissions"
// claim, this map is never consulted — the default mapper path handles it directly.
var emailPermissions = map[string][]string{
	"admin@temporal.io": {"temporal-system:admin", "default:admin"},
}

// defaultAuthenticatedPermissions is granted to any authenticated JWT that has
// no "permissions" claim AND no matching email in emailPermissions above.
// Grants worker + reader on the default namespace.
// Set to nil to deny all unrecognized identities.
var defaultAuthenticatedPermissions = []string{"default:worker", "default:reader"}

// customClaimMapper wraps the default JWT claim mapper.
//   - If the JWT has a "permissions" claim: default mapper handles it (production IDP path).
//   - If not: falls back to email-based mapping (Dex static passwords path).
type customClaimMapper struct {
	defaultMapper authorization.ClaimMapper
	logger        log.Logger
}

var _ authorization.ClaimMapper = (*customClaimMapper)(nil)

// NewCustomClaimMapper constructs the claim mapper. cfg must have JwtKeyProvider
// populated so JWT signatures can be validated.
func NewCustomClaimMapper(cfg *config.Authorization, logger log.Logger) authorization.ClaimMapper {
	defaultMapper := authorization.NewDefaultJWTClaimMapper(
		authorization.NewDefaultTokenKeyProvider(cfg, logger),
		cfg,
		logger,
	)
	return &customClaimMapper{
		defaultMapper: defaultMapper,
		logger:        logger,
	}
}

func (m *customClaimMapper) GetClaims(authInfo *authorization.AuthInfo) (*authorization.Claims, error) {
	// Default mapper validates JWT signature, expiry, audience, and extracts
	// permissions claim if present.
	claims, err := m.defaultMapper.GetClaims(authInfo)
	if err != nil {
		return nil, err
	}

	// Default mapper populated roles → JWT had a permissions claim → done.
	if len(claims.Namespaces) > 0 || claims.System != authorization.RoleUndefined {
		return claims, nil
	}

	// No permissions claim (Dex static passwords path) → fall back to email mapping.
	if authInfo.AuthToken == "" {
		return claims, nil
	}

	email := extractEmailFromBearer(authInfo.AuthToken)
	perms, ok := emailPermissions[strings.ToLower(email)]
	if !ok {
		perms = defaultAuthenticatedPermissions
	}

	return applyPermissions(claims, perms), nil
}

// applyPermissions maps "namespace:role" strings onto the Claims struct.
func applyPermissions(claims *authorization.Claims, perms []string) *authorization.Claims {
	if perms == nil {
		return claims
	}
	for _, p := range perms {
		parts := strings.SplitN(p, ":", 2)
		if len(parts) != 2 {
			continue
		}
		namespace, roleStr := parts[0], parts[1]
		role := stringToRole(roleStr)
		if role == authorization.RoleUndefined {
			continue
		}
		if namespace == "temporal-system" {
			claims.System |= role
		} else {
			if claims.Namespaces == nil {
				claims.Namespaces = make(map[string]authorization.Role)
			}
			claims.Namespaces[namespace] |= role
		}
	}
	return claims
}

func stringToRole(s string) authorization.Role {
	switch strings.ToLower(s) {
	case "read":
		return authorization.RoleReader
	case "write":
		return authorization.RoleWriter
	case "admin":
		return authorization.RoleAdmin
	case "worker":
		return authorization.RoleWorker
	}
	return authorization.RoleUndefined
}

// extractEmailFromBearer decodes the JWT payload (without re-validating the
// signature — the default mapper already did that) to extract the email claim.
func extractEmailFromBearer(bearerToken string) string {
	parts := strings.SplitN(bearerToken, " ", 2)
	if len(parts) != 2 {
		return ""
	}
	tokenParts := strings.SplitN(parts[1], ".", 3)
	if len(tokenParts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(tokenParts[1])
	if err != nil {
		return ""
	}
	var jwtClaims map[string]any
	if err := json.Unmarshal(payload, &jwtClaims); err != nil {
		return ""
	}
	email, _ := jwtClaims["email"].(string)
	return email
}
