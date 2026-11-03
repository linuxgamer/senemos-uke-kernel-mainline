
Release53 security candidate, 30 October 2026: require SHA-256 module signatures
from the certificate generated on the COPR worker, enable integrity lockdown,
FORTIFY, hardened usercopy, Yama and restricted kernel logs. The public certificate
is retained with the exact versioned kernel identity; the private key is removed
after the final Image build and is not an RPM payload. A rebuild generates a new
key and must retain its own matched Image/modules/certificate tuple. This does
not establish Secure Boot or physical tablet acceptance. Integrity lockdown
restricts unsigned external modules and some debugfs operations. The existing
optional prebuilt switch-root path remains disabled for the native COPR build.

Current source workers reject a published kernel NVR or an older release before
building. Keep the original matched artifacts for recovery and submit each new
release once. Direct administrative resubmission of a historical SRPM must also
use a fresh release; the source-worker guard cannot intercept that separate path.
