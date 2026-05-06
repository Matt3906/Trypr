import pandas as pd


def clean_inventory(df):
    """
    Return a cleaned copy of the DataFrame with these rules:
    - convert 'date' to datetime
    - fill missing values in 'price' with the mean of the column
    """
    raise NotImplementedError


def add_in_stock_flag(df):
    """
    Return a copy of the DataFrame with a boolean column named 'in_stock'
    that is True when stock is greater than 0.
    """
    raise NotImplementedError


def average_price_by_category(df):
    """
    Return a pandas Series containing the mean price for each category.
    """
    raise NotImplementedError


def low_stock_items(df):
    """
    Return only the rows where stock is less than 5.
    """
    raise NotImplementedError


def item_counts_by_month(df):
    """
    Return a pandas Series counting rows by month number, sorted by month.
    """
    raise NotImplementedError
