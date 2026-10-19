#!/usr/bin/env python3
"""Validate public Sparkle configuration before building or touching signing credentials.

This checks configuration shape only. A real Ed25519 signature over the final archive
must separately prove that the release owner possesses the matching Keychain key.
"""

import base64
import binascii
import ipaddress
from urllib.parse import urlsplit


def update_configuration(feed_url, public_key, *, required=False):
    """Return Info.plist fields, or reject missing/unsafe configuration as a pair."""
    if not feed_url and not public_key:
        if required:
            raise ValueError("Distribution requires --feed-url and --ed-public-key for optional updates.")
        return {}
    if not feed_url or not public_key:
        raise ValueError("Supply --feed-url and --ed-public-key together.")
    if not isinstance(feed_url, str) or feed_url != feed_url.strip() or any(c.isspace() for c in feed_url):
        raise ValueError("The update feed must be an HTTPS URL without whitespace.")
    try:
        url = urlsplit(feed_url)
        hostname = url.hostname
        port = url.port
    except ValueError as error:
        raise ValueError("Malformed update feed URL.") from error
    if (url.scheme != "https" or not hostname or url.username is not None
            or url.password is not None or url.fragment or url.query or port not in (None, 443)
            or not url.path.startswith("/") or "\\" in feed_url):
        raise ValueError("The feed requires HTTPS, a public host and a path; no credentials, query or fragment.")
    host = hostname.lower().rstrip(".")
    if host == "localhost" or host.endswith((".localhost", ".local")) or "." not in host:
        raise ValueError("The update feed host must be public.")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise ValueError("The update feed cannot use a private or loopback address.")
    if not isinstance(public_key, str):
        raise ValueError("The public update key must be canonical base64 containing 32 bytes.")
    try:
        decoded = base64.b64decode(public_key, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("The public update key must be canonical base64 containing 32 bytes.") from error
    if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != public_key or not any(decoded):
        raise ValueError("The public update key must be canonical base64 containing 32 bytes, not a zero placeholder.")
    return {"SUFeedURL": feed_url, "SUPublicEDKey": public_key}
