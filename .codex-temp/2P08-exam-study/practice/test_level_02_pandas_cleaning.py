import numpy as np
import pandas as pd
import pytest

import level_02_pandas_cleaning_starter as level


@pytest.fixture
def inventory_df():
    return pd.DataFrame(
        {
            "item": ["pen", "book", "game", "lamp"],
            "category": ["school", "school", "fun", "home"],
            "price": [2.5, np.nan, 30.0, 20.0],
            "stock": [12, 3, 0, 4],
            "date": ["2026-01-02", "2026-01-15", "2026-02-01", "2026-02-09"],
        }
    )


def test_clean_inventory(inventory_df):
    cleaned = level.clean_inventory(inventory_df)
    assert pd.api.types.is_datetime64_any_dtype(cleaned["date"])
    assert cleaned["price"].isna().sum() == 0
    assert cleaned.loc[1, "price"] == pytest.approx((2.5 + 30.0 + 20.0) / 3)


def test_add_in_stock_flag(inventory_df):
    updated = level.add_in_stock_flag(inventory_df)
    assert "in_stock" in updated.columns
    assert updated["in_stock"].dtype == bool
    assert updated["in_stock"].tolist() == [True, True, False, True]


def test_average_price_by_category(inventory_df):
    cleaned = level.clean_inventory(inventory_df)
    result = level.average_price_by_category(cleaned)
    assert isinstance(result, pd.Series)
    assert result["school"] == pytest.approx((2.5 + ((2.5 + 30.0 + 20.0) / 3)) / 2)
    assert result["fun"] == pytest.approx(30.0)


def test_low_stock_items(inventory_df):
    result = level.low_stock_items(inventory_df)
    assert isinstance(result, pd.DataFrame)
    assert result["item"].tolist() == ["book", "game", "lamp"]


def test_item_counts_by_month(inventory_df):
    result = level.item_counts_by_month(inventory_df)
    assert isinstance(result, pd.Series)
    assert result.to_dict() == {1: 2, 2: 2}
