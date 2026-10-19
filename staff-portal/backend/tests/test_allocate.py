from app.allocate import allocate


def test_n20_matches_legacy_ranges():
    a = allocate(20)
    assert a["All_Company"] == list(range(1, 21))
    assert a["Dev_Team"] == list(range(1, 11))
    assert a["QA_Team"] == list(range(11, 21))
    assert a["Support_Team"] == list(range(1, 6))
    assert a["Marketing_Team"] == list(range(6, 11))


def test_n50_proportional():
    a = allocate(50)
    assert a["Dev_Team"] == list(range(1, 26))
    assert a["QA_Team"] == list(range(26, 51))
    assert a["Support_Team"] == list(range(1, 13))      # floor(50/4)=12
    assert a["Marketing_Team"] == list(range(13, 26))   # 13..floor(50/2)=25


def test_small_n_edges():
    assert allocate(1) == {
        "All_Company": [1], "Dev_Team": [1], "QA_Team": [],
        "Support_Team": [], "Marketing_Team": [],
    }
    a2 = allocate(2)
    assert a2["Dev_Team"] == [1] and a2["QA_Team"] == [2]
    assert a2["Support_Team"] == [] and a2["Marketing_Team"] == [1]
