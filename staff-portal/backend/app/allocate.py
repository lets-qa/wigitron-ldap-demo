"""Authoritative, deterministic group-allocation rule. Pure: no I/O."""


def allocate(n: int) -> dict[str, list[int]]:
    half_lo = n // 2          # floor(N/2): Marketing upper bound, QA start anchor
    half_hi = (n + 1) // 2    # ceil(N/2): Dev gets the lone/odd user
    quarter = n // 4
    return {
        "All_Company": list(range(1, n + 1)),
        "Dev_Team": list(range(1, half_hi + 1)),
        "QA_Team": list(range(half_hi + 1, n + 1)),
        "Support_Team": list(range(1, quarter + 1)),
        "Marketing_Team": list(range(quarter + 1, half_lo + 1)),
    }
