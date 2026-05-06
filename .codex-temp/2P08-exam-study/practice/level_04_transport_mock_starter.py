import pandas as pd


def load_transport_data(csv_path):
    """
    Load the CSV file and return a DataFrame.
    """
    raise NotImplementedError


def clean_transport_data(df):
    """
    Return a cleaned copy of the DataFrame with these rules:
    - convert 'tpep_pickup_datetime' to datetime
    - convert 'tpep_dropoff_datetime' to datetime
    """
    raise NotImplementedError


def add_trip_minutes(df):
    """
    Return a copy of the DataFrame with a new column named 'trip_minutes'
    representing the trip duration in minutes.
    """
    raise NotImplementedError


def mean_total_by_payment_type(df):
    """
    Return a pandas Series containing the mean total amount for each payment type.
    """
    raise NotImplementedError


def busiest_pickup_hour(df):
    """
    Return the pickup hour with the most trips.
    """
    raise NotImplementedError


def long_trip_rate(df):
    """
    Return the proportion of trips whose distance is at least 5.0 miles.
    """
    raise NotImplementedError
