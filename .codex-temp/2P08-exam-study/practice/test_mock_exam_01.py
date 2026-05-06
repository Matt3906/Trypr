import numpy as np
import pandas as pd
import pytest

import mock_exam_01_starter as exam


@pytest.fixture
def store_df():
    return pd.DataFrame(
        {
            "date": ["2026-01-03", "2026-01-05", "2026-02-10", "2026-02-14"],
            "category": ["books", "books", "games", "games"],
            "sales": [120.0, np.nan, 80.0, 100.0],
        }
    )


def test_build_even_array():
    result = exam.build_even_array()
    assert isinstance(result, np.ndarray)
    assert np.array_equal(result, np.array([2, 4, 6, 8, 10, 12, 14, 16, 18, 20]))


def test_reshape_grades():
    result = exam.reshape_grades()
    assert isinstance(result, np.ndarray)
    assert result.shape == (3, 4)
    assert result[0, 0] == 10
    assert result[-1, -1] == 21


def test_curve_scores():
    scores = np.array([70, 82, 91])
    result = exam.curve_scores(scores)
    assert np.array_equal(result, np.array([75, 87, 96]))


def test_exam_average_by_student():
    grades = np.array([[80, 90, 100], [70, 75, 80]])
    result = exam.exam_average_by_student(grades)
    assert np.array_equal(result, np.array([90.0, 75.0]))


def test_clean_store_data(store_df):
    cleaned = exam.clean_store_data(store_df)
    assert pd.api.types.is_datetime64_any_dtype(cleaned["date"])
    assert cleaned["sales"].isna().sum() == 0
    assert cleaned.loc[1, "sales"] == pytest.approx((120.0 + 80.0 + 100.0) / 3)


def test_add_is_weekend(store_df):
    updated = exam.add_is_weekend(store_df)
    assert "is_weekend" in updated.columns
    assert updated["is_weekend"].dtype == bool
    assert updated["is_weekend"].tolist() == [True, False, False, True]


def test_mean_sales_by_category(store_df):
    cleaned = exam.clean_store_data(store_df)
    result = exam.mean_sales_by_category(cleaned)
    assert isinstance(result, pd.Series)
    assert result["books"] == pytest.approx(110.0)
    assert result["games"] == pytest.approx(90.0)


def test_orders_per_month(store_df):
    result = exam.orders_per_month(store_df)
    assert isinstance(result, pd.Series)
    assert result.to_dict() == {1: 2, 2: 2}
