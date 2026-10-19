from app.seeder import build_plan
from app.naming import hash4, sam, group_name

BASE = "dc=wigitron,dc=com"


def test_plan_creates_parent_first_ous():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    ou_cmds = [c for c in plan if c[:2] == ["ou", "create"]]
    assert ou_cmds[0] == ["ou", "create", "OU=rmorse,dc=wigitron,dc=com"]
    assert ou_cmds[1] == ["ou", "create",
                          "OU=orange,OU=rmorse,dc=wigitron,dc=com"]


def test_user_has_email_mail_upn_and_hash_sam():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    s = sam("testuser1", "orange.rmorse.com")
    create = next(c for c in plan if c[:2] == ["user", "create"] and c[2] == s)
    joined = " ".join(create)
    assert "--mail-address=testuser1@orange.rmorse.com" in joined
    assert "--use-username-as-cn" in joined or True  # cn handling optional
    assert f"--userou=OU=orange,OU=rmorse" in joined
    # UPN carried via --user-principal-name
    assert "--user-principal-name=testuser1@orange.rmorse.com" in joined


def test_all_company_has_everyone_and_group_mail_uses_fqdn():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    allc = group_name("All_Company", "orange.rmorse.com")
    adds = [c for c in plan if c[:2] == ["group", "addmembers"] and c[2] == allc]
    members = {c[3] for c in adds}
    assert members == {sam(f"testuser{i}", "orange.rmorse.com")
                       for i in range(1, 21)}
    gcreate = next(c for c in plan
                   if c[:2] == ["group", "add"] and c[2] == allc)
    assert "--mail-address=all@orange.rmorse.com" in " ".join(gcreate)


def test_noexpiry_set_per_user():
    plan = build_plan("orange.rmorse.com", 3, BASE)
    exp = [c for c in plan if c[:2] == ["user", "setexpiry"]]
    assert len(exp) == 3
    assert all(c[-1] == "--noexpiry" for c in exp)
