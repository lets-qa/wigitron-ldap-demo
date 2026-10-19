# staff-portal/backend/tests/test_naming.py
import pytest
from app.naming import normalize_fqdn, hash4, ou_path, sam, group_name


def test_normalize():
    assert normalize_fqdn("  Orange.Rmorse.Com. ") == "orange.rmorse.com"
    with pytest.raises(ValueError):
        normalize_fqdn("")
    with pytest.raises(ValueError):
        normalize_fqdn("localhost")


def test_hash_stable_and_short():
    assert hash4("orange.rmorse.com") == hash4("ORANGE.rmorse.com.")
    assert len(hash4("orange.rmorse.com")) == 4
    # longest sAMAccountName must stay within AD's 20-char cap
    assert len(sam("testuser500", "orange.rmorse.com")) <= 20


def test_ou_path_nested_parent_first():
    base = "dc=wigitron,dc=com"
    assert ou_path("rmorse.com", base) == ["OU=rmorse,dc=wigitron,dc=com"]
    assert ou_path("orange.rmorse.com", base) == [
        "OU=rmorse,dc=wigitron,dc=com",
        "OU=orange,OU=rmorse,dc=wigitron,dc=com",
    ]


def test_names_suffixed():
    h = hash4("orange.rmorse.com")
    assert sam("testuser1", "orange.rmorse.com") == f"testuser1_{h}"
    assert group_name("Dev_Team", "orange.rmorse.com") == f"Dev_Team_{h}"
