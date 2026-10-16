import pytest

from report import COLUMNS, report


def run(conc, ttft, failed=0):
    r = {k: 1.0 for _, k in COLUMNS}
    return r | {"max_concurrency": conc, "median_ttft_ms": ttft, "failed": failed}


def test_median_of_repeats_per_concurrency():
    table = report([run(4, 30), run(1, 10), run(4, 10), run(4, 20)]).splitlines()
    assert table[2].startswith("| 1 | 1 | 1.0 | 1.0 | 10.0 |")
    assert table[3].startswith("| 4 | 3 | 1.0 | 1.0 | 20.0 |")


def test_failed_requests_fail_the_report():
    with pytest.raises(SystemExit):
        report([run(1, 10, failed=1)])
