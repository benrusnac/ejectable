# Security policy

Please report security problems privately through GitHub's
[private vulnerability reporting](../../security/advisories/new) (Security tab › Report a vulnerability), not in a
public issue. In scope: anything that lets Ejectable eject, force-unmount, quit or signal something without the
user's explicit click, act on the wrong disk or process, bypass the Force Eject safety checks, or leak file paths
beyond the local, user-only action log; also the debug entry points (`EJECTABLE_DEBUG`) if they can be reached in a
release build. Out of scope: Apple's own unmount dialog, macOS itself, and the fact that the app is not sandboxed or
notarized (both are documented). You can expect a reply within a week; fixes ship as a new release with credit unless
you prefer otherwise.
