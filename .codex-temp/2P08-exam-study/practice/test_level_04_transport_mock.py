from pathlib import Path

import pandas as pd
import pytest

import level_04_transport_mock_starter as level


DATA_PATH = Path(__file__).with_name("data") / "public_transport_sample.csv"


def test_load_transport_data():
    df = level.load_transport_data(DATA_PATH)
    assert isinstance(df, pd.DataFrame)
    assert len(df) == 8
    assert "trip_distance" in df.columns


def test_clean_transport_data():
    df = level.load_transport_data(DATA_PATH)
    cleaned = level.clean_transport_data(df)
    assert pd.api.types.is_datetime64_any_dtype(cleaned["tpep_pickup_datetime"])
    assert pd.api.types.is_datetime64_any_dtype(cleaned["tpep_dropoff_datetime"])


def test_add_trip_minutes():
    df = level.clean_transport_data(level.load_transport_data(DATA_PATH))
    updated = level.add_trip_minutes(df)
    assert "trip_minutes" in updated.columns
    assert updated.loc[0, "trip_minutes"] == pytest.approx(15.0)
    assert updated.loc[5, "trip_minutes"] == pytest.approx(50.0)


def test_mean_total_by_payment_type():
    df = level.clean_transport_data(level.load_transport_data(DATA_PATH))
    result = level.mean_total_by_payment_type(df)
    assert isinstance(result, pd.Series)
    assert result[1] == pytest.approx((15.3 + 13.1 + 33.3 + 42.1 + 17.0) / 5)
    assert result[2] == pytest.approx((20.8 + 18.8 + 7.3) / 3)


def test_busiest_pickup_hour():
    df = level.clean_transport_data(level.load_transport_data(DATA_PATH))
    assert level.busiest_pickup_hour(df) == 8


def test_long_trip_rate():
    df = level.clean_transport_data(level.load_transport_data(DATA_PATH))
    assert level.long_trip_rate(df) == pytest.approx(3 / 8)
