import pandas as pd


def clean_inventory(df):
    cleaned = df.copy()
    cleaned["date"] = pd.to_datetime(cleaned["date"])
    cleaned["price"] = cleaned["price"].fillna(cleaned["price"].mean())
    return cleaned


def add_in_stock_flag(df):
    updated = df.copy()
    updated["in_stock"] = updated["stock"] > 0
    return updated


def average_price_by_category(df):
    return df.groupby("category")["price"].mean()


def low_stock_items(df):
    return df[df["stock"] < 5]


def item_counts_by_month(df):
    dates = pd.to_datetime(df["date"])
    return dates.dt.month.value_counts().sort_index()
