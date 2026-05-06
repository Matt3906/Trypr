import numpy as np
import pandas as pd


def build_even_array():
    return np.array([x for x in range(2, 21, 2)])


def reshape_grades():
    return np.arange(10, 22).reshape(3, 4)


def curve_scores(scores):
    return scores + 5


def exam_average_by_student(grades):
    return grades.mean(axis=1)


def clean_store_data(df):
    cleaned = df.copy()
    cleaned["date"] = pd.to_datetime(cleaned["date"])
    cleaned["sales"] = cleaned["sales"].fillna(cleaned["sales"].mean())
    return cleaned


def add_is_weekend(df):
    updated = df.copy()
    updated["date"] = pd.to_datetime(updated["date"])
    updated["is_weekend"] = updated["date"].dt.dayofweek >= 5
    return updated


def mean_sales_by_category(df):
    return df.groupby("category")["sales"].mean()


def orders_per_month(df):
    dates = pd.to_datetime(df["date"])
    return dates.dt.month.value_counts().sort_index()
