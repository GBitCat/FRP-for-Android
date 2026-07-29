# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in FRP Android, please report it responsibly.

### How to Report
1. **Do not** open a public GitHub issue
2. Email security concerns to [security@example.com]
3. Include detailed information about the vulnerability
4. Provide steps to reproduce if possible

### What to Include
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline
- **Initial Response**: Within 48 hours
- **Status Update**: Within 1 week
- **Fix Release**: Depends on severity

## Security Best Practices

### For Users
1. **Keep the app updated**: Always use the latest version
2. **Use strong tokens**: Use complex, unique tokens for FRP connections
3. **Limit permissions**: Only grant necessary permissions
4. **Monitor connections**: Regularly check active connections
5. **Use HTTPS**: Prefer HTTPS connections when possible

### For Developers
1. **Input validation**: Validate all user inputs
2. **Secure storage**: Use Android Keystore for sensitive data
3. **Network security**: Use HTTPS and certificate pinning
4. **Code review**: All code changes require review
5. **Dependency updates**: Keep dependencies updated

## Security Features

### Current Security Measures
- Token-based authentication for FRP connections
- Local storage encryption for sensitive data
- Network traffic encryption (when using HTTPS)
- Permission-based access control

### Planned Security Features
- Certificate pinning for FRP server connections
- Biometric authentication for app access
- VPN integration for secure tunnels
- Audit logging for security events

## Vulnerability Disclosure

We follow responsible disclosure principles:
1. Report vulnerabilities privately
2. Allow reasonable time for fixes
3. Credit reporters in security advisories
4. Publish security updates promptly

## Contact

For security-related questions or concerns:
- Email: [security@example.com]
- GitHub: Use private vulnerability reporting

## Acknowledgments

We thank security researchers who responsibly disclose vulnerabilities.
