import pandas as pd


def load_transport_data(csv_path):
    return pd.read_csv(csv_path)


def clean_transport_data(df):
    cleaned = df.copy()
    cleaned["tpep_pickup_datetime"] = pd.to_datetime(cleaned["tpep_pickup_datetime"])
    cleaned["tpep_dropoff_datetime"] = pd.to_datetime(cleaned["tpep_dropoff_datetime"])
    return cleaned


def add_trip_minutes(df):
    updated = df.copy()
    updated["trip_minutes"] = (
        updated["tpep_dropoff_datetime"] - updated["tpep_pickup_datetime"]
    ).dt.total_seconds() / 60
    return updated


def mean_total_by_payment_type(df):
    return df.groupby("payment_type")["total_amount"].mean()


def busiest_pickup_hour(df):
    return int(df["tpep_pickup_datetime"].dt.hour.value_counts().idxmax())


def long_trip_rate(df):
    return float((df["trip_distance"] >= 5.0).mean())
