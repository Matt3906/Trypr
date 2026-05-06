import numpy as np
import pandas as pd


def build_even_array():
    """
    Return a 1D NumPy array containing the even integers from 2 through 20.
    """
    raise NotImplementedError


def reshape_grades():
    """
    Create a NumPy array containing the values 10 through 21, then reshape it
    into 3 rows and 4 columns.
    """
    raise NotImplementedError


def curve_scores(scores):
    """
    Given a NumPy array of scores, return a new array in which every score is
    increased by 5 using element-wise arithmetic.
    """
    raise NotImplementedError


def exam_average_by_student(grades):
    """
    Given a 2D NumPy array where each row is a student, return the average
    grade for each student.
    """
    raise NotImplementedError


def clean_store_data(df):
    """
    Return a cleaned copy of the DataFrame with these rules:
    - convert the 'date' column to datetime
    - fill missing values in 'sales' with the mean of the sales column
    """
    raise NotImplementedError


def add_is_weekend(df):
    """
    Return a copy of the DataFrame with a boolean column named 'is_weekend'
    that is True when the date falls on Saturday or Sunday.
    """
    raise NotImplementedError


def mean_sales_by_category(df):
    """
    Return a pandas Series containing the mean sales for each category.
    """
    raise NotImplementedError


def orders_per_month(df):
    """
    Return a pandas Series that counts how many rows belong to each month
    number, sorted by month.
    """
    raise NotImplementedError
