# Security

Tessera can read and type into your terminals and open your agent conversations, and its iPhone
link lets a paired device do the same. Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/Enntity/tessera/security/advisories/new) rather
than a public issue.

The local agent API is bound to loopback and uses a random token in a user-only file. It is a
coordination tool for processes running as the same macOS user, not an isolation boundary
between mutually untrusted agents. Tile identities are caller-supplied hints. See the
[control-plane trust model](docs/control-plane.md#trust-and-privacy).

The optional iPhone link is disabled by default. A paired client can read and type into
terminals and launch commands. Its TLS-PSK channel does not currently provide forward secrecy;
the [README](README.md#architecture) describes that separate boundary.

Steward sends selected board content to the endpoint configured by the user. Pattern-based
redaction removes common credentials, but cannot recognize every secret. Privacy mode prevents
new content reads and requests; it cannot recall data already sent.
