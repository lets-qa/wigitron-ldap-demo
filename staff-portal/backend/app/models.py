from pydantic import BaseModel, Field

# Hostname-shape validation: 2+ dot-separated labels, each 1-63 chars of
# [a-z0-9-] not starting/ending with a hyphen, TLD alphabetic. Rejects
# malformed input like ".com", "a..b", "-x.com", "x_y.com" before it can
# produce an empty-label OU DN. Case-insensitive (normalize lowercases anyway).
# No look-ahead: pydantic v2's regex engine (Rust) does not support it, so the
# overall length cap is enforced via max_length on the field instead.
_FQDN_PATTERN = (
    r"(?i)^"
    r"([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z]{2,63}$"
)


class CreateDomain(BaseModel):
    fqdn: str = Field(
        ..., pattern=_FQDN_PATTERN, max_length=253, examples=["orange.rmorse.com"]
    )
    user_count: int = Field(20, ge=1, le=500)
    dry_run: bool = False
